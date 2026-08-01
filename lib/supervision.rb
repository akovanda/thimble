# frozen_string_literal: true

module Thimble
  class CancelledError < RuntimeError
    attr_reader :reason

    def initialize(message = 'execution cancelled', reason: nil)
      @reason = reason
      super(message)
    end
  end

  class StageTimeoutError < CancelledError
    attr_reader :execution_name, :timeout

    def initialize(execution_name:, timeout:)
      @execution_name = execution_name
      @timeout = timeout
      super("#{execution_name} exceeded its #{timeout}-second timeout")
    end
  end

  class WorkerTimeoutError < StageTimeoutError
    attr_reader :worker_id, :batch_size

    def initialize(execution_name:, timeout:, worker_id:, batch_size:)
      @worker_id = worker_id
      @batch_size = batch_size
      super(execution_name: execution_name, timeout: timeout)
    end

    def message
      "#{execution_name} worker #{worker_id} exceeded its #{timeout}-second timeout while processing #{batch_size} item(s)"
    end
  end

  ShutdownRequest = Struct.new(:mode, :reason, :error, :requested_at, keyword_init: true) do
    def graceful?
      mode == :graceful
    end

    def immediate?
      mode == :immediate
    end
  end

  class CancellationToken
    MODES = %i[graceful immediate].freeze

    class Subscription
      def initialize(token, id)
        @token = token
        @id = id
      end

      def unsubscribe
        return false unless @token

        removed = @token.__send__(:unsubscribe, @id)
        @token = nil
        removed
      end
    end

    def initialize
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @request = nil
      @callbacks = {}
      @next_callback_id = 0
    end

    def cancel(reason = nil)
      request_shutdown(mode: :immediate, reason: reason)
    end

    def drain(reason = nil)
      request_shutdown(mode: :graceful, reason: reason)
    end

    def shutdown(mode:, reason: nil)
      request_shutdown(mode: mode, reason: reason)
    end

    def request_shutdown(mode:, reason: nil)
      validate_mode!(mode)
      new_request = build_request(mode, reason)
      callbacks = nil

      changed = @mutex.synchronize do
        current = @request
        next false if current&.immediate?
        next false if current&.mode == mode

        @request = new_request
        callbacks = @callbacks.values
        @callbacks.clear if new_request.immediate?
        @condition.broadcast
        true
      end
      return false unless changed

      callbacks.each do |callback|
        callback.call(new_request)
      rescue StandardError
        # Every subscriber must observe shutdown even if one callback fails.
        nil
      end
      true
    end

    def shutdown?
      @mutex.synchronize { !@request.nil? }
    end

    def draining?
      @mutex.synchronize { @request&.graceful? || false }
    end

    def cancelled?
      @mutex.synchronize { @request&.immediate? || false }
    end
    alias canceled? cancelled?

    def request
      @mutex.synchronize { @request }
    end

    def error
      current = request
      current&.error if current&.immediate?
    end

    def reason
      request&.reason
    end

    def checkpoint!
      cancellation = error
      raise cancellation if cancellation

      self
    end

    # Preserves the historical behavior: immediate cancellation returns its
    # exception. A graceful request returns a ShutdownRequest.
    def wait(timeout: nil)
      current = wait_for_shutdown(timeout: timeout)
      return nil unless current

      current.immediate? ? current.error : current
    end

    def wait_for_shutdown(timeout: nil)
      validate_wait_timeout!(timeout)
      deadline = monotonic_now + timeout if timeout

      @mutex.synchronize do
        until @request
          remaining = deadline && deadline - monotonic_now
          return nil if remaining && remaining <= 0

          @condition.wait(@mutex, remaining)
        end
        @request
      end
    end

    # Waits only for immediate cancellation. Graceful drain requests wake the
    # waiter so it can re-evaluate the remaining timeout, but do not interrupt
    # retry backoff for already accepted work.
    def wait_for_cancel(timeout: nil)
      validate_wait_timeout!(timeout)
      deadline = monotonic_now + timeout if timeout

      @mutex.synchronize do
        until @request&.immediate?
          remaining = deadline && deadline - monotonic_now
          return nil if remaining && remaining <= 0

          @condition.wait(@mutex, remaining)
        end
        @request.error
      end
    end

    def on_shutdown(&block)
      raise ArgumentError, 'on_shutdown requires a block' unless block

      current = nil
      subscription = @mutex.synchronize do
        current = @request
        if current&.immediate?
          nil
        else
          @next_callback_id += 1
          id = @next_callback_id
          @callbacks[id] = block
          Subscription.new(self, id)
        end
      end

      block.call(current) if current
      subscription
    end

    def on_cancel(&block)
      raise ArgumentError, 'on_cancel requires a block' unless block

      on_shutdown do |shutdown_request|
        block.call(shutdown_request.error) if shutdown_request.immediate?
      end
    end

    private

    def unsubscribe(id)
      @mutex.synchronize { !@callbacks.delete(id).nil? }
    end

    def build_request(mode, reason)
      error = normalize_error(reason) if mode == :immediate
      ShutdownRequest.new(
        mode: mode,
        reason: reason,
        error: error,
        requested_at: Time.now
      )
    end

    def normalize_error(reason)
      return CancelledError.new if reason.nil?
      return reason if reason.is_a?(Exception)

      CancelledError.new("execution cancelled: #{reason}", reason: reason)
    end

    def validate_mode!(mode)
      return if MODES.include?(mode)

      raise ArgumentError, 'shutdown mode must be :graceful or :immediate'
    end

    def validate_wait_timeout!(timeout)
      return if timeout.nil?
      return if timeout.is_a?(Numeric) && timeout >= 0 && (!timeout.respond_to?(:finite?) || timeout.finite?)

      raise ArgumentError, 'timeout must be a finite number greater than or equal to 0'
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end

  class Execution
    STATES = %i[pending running draining cancelling succeeded drained failed cancelled timed_out].freeze
    TERMINAL_STATES = %i[succeeded drained failed cancelled timed_out].freeze

    attr_reader :name, :timeout, :token

    def initialize(name:, timeout: nil, token: nil)
      validate_timeout!(timeout, allow_nil: true)
      unless token.nil? || token.is_a?(CancellationToken)
        raise ArgumentError, 'cancellation must be a Thimble::CancellationToken'
      end

      @name = name
      @timeout = timeout
      @token = token || CancellationToken.new
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @state = :pending
      @error = nil
      @shutdown_request = nil
      @started_at = nil
      @finished_at = nil
      @started_monotonic = nil
      @deadline_monotonic = nil

      @token_subscription = @token.on_shutdown do |request|
        @mutex.synchronize do
          next if terminal_unlocked?

          @shutdown_request = request
          if request.immediate?
            @state = :cancelling
            @error ||= request.error
          elsif @state != :cancelling
            @state = :draining
          end
          @condition.broadcast
        end
      end
    end

    def start!
      @mutex.synchronize do
        raise RuntimeError, "#{name} has already finished" if terminal_unlocked?

        unless @started_at
          @started_at = Time.now
          @started_monotonic = monotonic_now
          @deadline_monotonic = @started_monotonic + timeout if timeout
        end
        @state = @token.draining? ? :draining : :running unless @token.cancelled?
        @condition.broadcast
      end
      checkpoint!
      self
    end

    def checkpoint!
      deadline = @mutex.synchronize { @deadline_monotonic }
      if deadline && monotonic_now >= deadline && !@token.cancelled?
        @token.cancel(StageTimeoutError.new(execution_name: name, timeout: timeout))
      end
      @token.checkpoint!
      self
    end

    def cancel(reason = nil)
      return false if finished?

      @token.cancel(cancellation_error(reason))
    end

    def drain(reason = nil)
      return false if finished?

      @token.drain(reason)
    end

    def shutdown(mode:, reason: nil)
      return false if finished?

      case mode
      when :immediate
        cancel(reason)
      when :graceful
        drain(reason)
      else
        raise ArgumentError, 'shutdown mode must be :graceful or :immediate'
      end
    end

    def succeed!
      checkpoint!
      @mutex.synchronize do
        return self if %i[succeeded drained].include?(@state)
        raise @error if @state == :cancelling && @error
        raise RuntimeError, "#{name} has already finished as #{@state}" if terminal_unlocked?

        @state = @token.draining? ? :drained : :succeeded
        @finished_at = Time.now
        @condition.broadcast
      end
      release_token_subscription
      self
    end

    def fail!(error)
      raise ArgumentError, 'error must be an Exception' unless error.is_a?(Exception)
      return self if finished?

      @token.cancel(error) unless @token.cancelled?
      terminal_error = @token.error || error

      @mutex.synchronize do
        unless terminal_unlocked?
          @error = terminal_error
          @state = terminal_state_for(terminal_error)
          @finished_at = Time.now
          @condition.broadcast
        end
      end
      release_token_subscription
      self
    end

    def wait(timeout: nil)
      validate_wait_timeout!(timeout)
      deadline = monotonic_now + timeout if timeout

      @mutex.synchronize do
        until terminal_unlocked?
          remaining = deadline && deadline - monotonic_now
          return nil if remaining && remaining <= 0

          @condition.wait(@mutex, remaining)
        end
      end
      self
    end

    def state
      @mutex.synchronize { @state }
    end

    def error
      @mutex.synchronize { @error }
    end

    def shutdown_request
      @mutex.synchronize { @shutdown_request }
    end

    def shutdown_reason
      shutdown_request&.reason
    end

    def started_at
      @mutex.synchronize { @started_at }
    end

    def finished_at
      @mutex.synchronize { @finished_at }
    end

    def duration
      started_monotonic, started_wall, finished_wall = @mutex.synchronize do
        [@started_monotonic, @started_at, @finished_at]
      end
      return nil unless started_monotonic

      finished_wall ? finished_wall - started_wall : monotonic_now - started_monotonic
    end

    def remaining_time
      deadline = @mutex.synchronize { @deadline_monotonic }
      return nil unless deadline

      [deadline - monotonic_now, 0.0].max
    end

    def finished?
      @mutex.synchronize { terminal_unlocked? }
    end

    def running?
      state == :running
    end

    def draining?
      state == :draining
    end

    def succeeded?
      state == :succeeded
    end

    def drained?
      state == :drained
    end

    def failed?
      state == :failed
    end

    def cancelled?
      state == :cancelled
    end
    alias canceled? cancelled?

    def timed_out?
      state == :timed_out
    end

    private

    def cancellation_error(reason)
      return reason if reason.is_a?(CancelledError)
      return CancelledError.new if reason.nil?

      message = if reason.is_a?(Exception)
                  "execution cancelled: #{reason.class}: #{reason.message}"
                else
                  "execution cancelled: #{reason}"
                end
      CancelledError.new(message, reason: reason)
    end

    def terminal_state_for(error)
      case error
      when StageTimeoutError
        :timed_out
      when CancelledError
        :cancelled
      else
        :failed
      end
    end

    def terminal_unlocked?
      TERMINAL_STATES.include?(@state)
    end

    def release_token_subscription
      @token_subscription&.unsubscribe
      @token_subscription = nil
    end

    def validate_timeout!(value, allow_nil:)
      return if allow_nil && value.nil?
      return if value.is_a?(Numeric) && value.positive? && (!value.respond_to?(:finite?) || value.finite?)

      raise ArgumentError, 'timeout must be a finite number greater than 0'
    end

    def validate_wait_timeout!(value)
      return if value.nil?
      return if value.is_a?(Numeric) && value >= 0 && (!value.respond_to?(:finite?) || value.finite?)

      raise ArgumentError, 'timeout must be a finite number greater than or equal to 0'
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
