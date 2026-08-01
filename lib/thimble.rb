# frozen_string_literal: true

require_relative 'supervision'
require_relative 'retry_policy'
require_relative 'shutdown_coordinator'
require_relative 'manager'
require_relative 'thimble_queue'
require_relative 'queue_item'
require_relative 'thimble/version'

module Thimble
  class Thimble < ThimbleQueue
    FAILURE_MODES = %i[raise continue].freeze

    def initialize(enumerable, manager = Manager.new, result = nil, name = 'Main')
      raise ArgumentError, 'You need to pass a manager to Thimble!' unless manager.instance_of?(Manager)
      unless enumerable.respond_to?(:each)
        raise ArgumentError, 'There needs to be an iterable object passed to Thimble to start.'
      end

      if result && (!result.instance_of?(ThimbleQueue) || result.closed?)
        raise ArgumentError, 'result needs to be an open ThimbleQueue'
      end

      @manager = manager
      @source_size = if enumerable.is_a?(ThimbleQueue)
                       nil
                     elsif enumerable.respond_to?(:size)
                       enumerable.size
                     end
      @result = result
      @source = enumerable
      @source_is_queue = enumerable.is_a?(ThimbleQueue)
      @source_thread = nil
      @coordinator_thread = nil
      @shutdown_subscription = nil
      @worker_timeout = nil
      @retry_policy = RetryPolicy.coerce(nil)
      @dead_letter = nil
      @failure_mode = :raise
      @structured_failures = false
      @attempt_context_enabled = false
      @started = false
      super(@manager.queue_size, name)
    end

    # Transforms each item and returns a result queue after all work finishes.
    def map(timeout: nil, worker_timeout: nil, cancellation: nil, retry_policy: nil,
            dead_letter: nil, failure_mode: nil, &block)
      start_sync(
        :map,
        batch_mode: false,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        retry_policy: retry_policy,
        dead_letter: dead_letter,
        failure_mode: failure_mode,
        &block
      )
    end

    # Sends each worker one array of up to Manager#batch_size items. This is
    # useful for bulk APIs, database writes, and other amortized operations.
    def map_batches(timeout: nil, worker_timeout: nil, cancellation: nil, retry_policy: nil,
                    dead_letter: nil, failure_mode: nil, &block)
      start_sync(
        :map_batches,
        batch_mode: true,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        retry_policy: retry_policy,
        dead_letter: dead_letter,
        failure_mode: failure_mode,
        &block
      )
    end

    # Runs #map in a coordinator thread and returns a bounded result queue
    # immediately. Consuming the result provides downstream backpressure.
    def map_async(timeout: nil, worker_timeout: nil, cancellation: nil, retry_policy: nil,
                  dead_letter: nil, failure_mode: nil, &block)
      start_async(
        :map_async,
        batch_mode: false,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        retry_policy: retry_policy,
        dead_letter: dead_letter,
        failure_mode: failure_mode,
        &block
      )
    end

    # Asynchronous form of #map_batches.
    def map_batches_async(timeout: nil, worker_timeout: nil, cancellation: nil,
                          retry_policy: nil, dead_letter: nil, failure_mode: nil, &block)
      start_async(
        :map_batches_async,
        batch_mode: true,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        retry_policy: retry_policy,
        dead_letter: dead_letter,
        failure_mode: failure_mode,
        &block
      )
    end

    def self.async(&block)
      Thread.new(&block)
    end

    private

    def start_sync(method_name, batch_mode:, timeout:, worker_timeout:, cancellation:,
                   retry_policy:, dead_letter:, failure_mode:, &block)
      validate_start!(method_name, block)
      capacity = sync_result_capacity
      prepare_execution(
        method_name,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        retry_policy: retry_policy,
        dead_letter: dead_letter,
        failure_mode: failure_mode
      )
      @started = true
      ensure_result(capacity)
      attach_execution_queues
      install_shutdown_handler

      begin
        @execution.start!
        start_source
        run_map(batch_mode: batch_mode, &block)
      rescue Exception => error # rubocop:disable Lint/RescueException -- preserve cancellation and interrupts
        effective_error = handle_failure(error)
        raise effective_error
      end
    end

    def start_async(method_name, batch_mode:, timeout:, worker_timeout:, cancellation:,
                    retry_policy:, dead_letter:, failure_mode:, &block)
      validate_start!(method_name, block)
      prepare_execution(
        method_name,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        retry_policy: retry_policy,
        dead_letter: dead_letter,
        failure_mode: failure_mode
      )
      @started = true
      ensure_result(@manager.queue_size)
      attach_execution_queues
      install_shutdown_handler

      begin
        @execution.start!
        start_source
      rescue Exception => error # rubocop:disable Lint/RescueException -- async failures travel through the result queue
        handle_failure(error)
        return @result
      end

      @coordinator_thread = Thimble.async do
        begin
          run_map(batch_mode: batch_mode, &block)
        rescue Exception => error # rubocop:disable Lint/RescueException -- result queue carries the failure
          handle_failure(error)
        end
      end
      @result
    end

    def validate_start!(method_name, block)
      raise ArgumentError, "#{method_name} requires a block" unless block
      raise RuntimeError, 'this Thimble has already been consumed' if @started
    end

    def prepare_execution(method_name, timeout:, worker_timeout:, cancellation:,
                          retry_policy:, dead_letter:, failure_mode:)
      validate_timeout_option!(:worker_timeout, worker_timeout)
      token = cancellation || CancellationToken.new
      unless token.is_a?(CancellationToken)
        raise ArgumentError, 'cancellation must be a Thimble::CancellationToken'
      end

      @worker_timeout = worker_timeout
      @retry_policy = RetryPolicy.coerce(retry_policy)
      @failure_mode = normalize_failure_mode(failure_mode)
      @dead_letter = validate_dead_letter!(dead_letter)
      if @failure_mode == :continue && @dead_letter.nil?
        raise ArgumentError, 'failure_mode :continue requires a dead_letter sink'
      end
      @structured_failures = !retry_policy.nil? || !dead_letter.nil? || !failure_mode.nil?
      @attempt_context_enabled = !retry_policy.nil?
      @execution = Execution.new(name: "#{@name}.#{method_name}", timeout: timeout, token: token)
    end

    def attach_execution_queues
      attach_execution(@execution)
      @result.attach_execution(@execution)
    end

    def install_shutdown_handler
      @shutdown_subscription = @execution.token.on_shutdown do |request|
        next if @execution.finished?

        if request.immediate?
          abort(request.error) unless closed?
          @result.abort(request.error) unless @result.closed?
        else
          wake_waiters
          @result.wake_waiters
        end
        @manager.signal_change
      end
    end

    def start_source
      @source_thread = Thread.new do
        begin
          if @source_is_queue
            stream_queue_source
          else
            stream_enumerable_source
          end
          close unless closed?
        rescue ClosedQueueError => error
          if @execution.draining?
            close unless closed?
          else
            abort(error) unless closed?
          end
          @manager.signal_change
        rescue Exception => error # rubocop:disable Lint/RescueException -- source failures propagate through the queue
          abort(error) unless closed?
          @manager.signal_change
        end
      end
    end

    def stream_queue_source
      while (queue_item = @source.next(control: @execution))
        push(queue_item.item, control: @execution)
      end
    end

    def stream_enumerable_source
      @source.each do |item|
        break if @execution.draining?

        accepted = push(item, control: @execution, stop_on_drain: true)
        break unless accepted
      end
    end

    def sync_result_capacity
      unless @source_size.is_a?(Integer)
        raise ArgumentError,
              'synchronous mapping requires an enumerable with a finite integer size; use map_async or map_batches_async for streaming sources'
      end

      [@source_size, 1].max
    end

    def ensure_result(capacity)
      @result ||= ThimbleQueue.new(capacity, 'Result')
    end

    def run_map(batch_mode:, &block)
      pending_batch = nil
      input_exhausted = false
      worker_block = build_worker_block(batch_mode, block)

      loop do
        @execution.checkpoint!
        @manager.completed_workers(@id).each { |worker| get_result(worker) }
        @execution.checkpoint!
        raise_worker_timeout!

        until input_exhausted || !@manager.worker_available?
          @execution.checkpoint!
          pending_batch ||= get_batch
          if pending_batch.nil?
            input_exhausted = true
            break
          end

          worker = @manager.start_worker(pending_batch, @id, batch_mode: batch_mode, &worker_block)
          break unless worker

          pending_batch = nil
        end

        break if input_exhausted && !@manager.working_for?(@id)

        @manager.wait_for_change(
          @id,
          wait_for_capacity: !input_exhausted,
          timeout: next_wait_timeout
        )
      end

      @execution.checkpoint!
      @source_thread.join
      @execution.succeed!
      @result.close
      release_shutdown_subscription
      @result
    end

    def get_batch
      batch = []
      while batch.size < @manager.batch_size
        item = self.next(control: @execution)
        if item.nil?
          return nil if batch.empty?

          return QueueItem.new(batch, 'Batch')
        end
        batch << item
      end
      QueueItem.new(batch, 'Batch')
    end

    def build_worker_block(batch_mode, block)
      proc do |input|
        execute_with_retries(input, batch_mode: batch_mode, block: block)
      end
    end

    def execute_with_retries(input, batch_mode:, block:)
      attempt = 0
      started_at = Time.now
      started_monotonic = monotonic_now
      batch_size = batch_mode ? input.size : 1
      worker_id = @manager.worker_type == :thread ? Thread.current.object_id : Process.pid

      loop do
        attempt += 1
        context = AttemptContext.new(
          execution_name: @execution.name,
          attempt: attempt,
          max_attempts: @retry_policy.max_attempts,
          input: input,
          batch_mode: batch_mode,
          batch_size: batch_size,
          worker_type: @manager.worker_type,
          worker_id: worker_id,
          started_at: Time.now
        )

        begin
          worker_checkpoint!
          value = invoke_user_block(block, input, context)
          worker_checkpoint!
          return WorkOutcome.success(value)
        rescue CancelledError
          raise
        rescue StandardError => error
          retryable = @retry_policy.retryable?(error, context)
          if retryable && attempt < @retry_policy.max_attempts
            delay = @retry_policy.delay_for(attempt)
            wait_for_retry_delay(delay)
            worker_checkpoint!
            next
          end

          failed_at = Time.now
          preserve_unmarshalable = @manager.worker_type == :thread
          failure = FailureContext.new(
            execution_name: @execution.name,
            payload: PayloadSnapshot.capture(input, preserve_unmarshalable: preserve_unmarshalable),
            attempt: attempt,
            max_attempts: @retry_policy.max_attempts,
            error_snapshot: ErrorSnapshot.capture(error, preserve_unmarshalable: preserve_unmarshalable),
            retryable: retryable,
            exhausted: retryable && attempt >= @retry_policy.max_attempts,
            batch_mode: batch_mode,
            batch_size: batch_size,
            worker_type: @manager.worker_type,
            worker_id: worker_id,
            started_at: started_at,
            failed_at: failed_at,
            elapsed: monotonic_now - started_monotonic
          )
          return WorkOutcome.failure(failure)
        end
      end
    end

    def worker_checkpoint!
      # A forked child must not touch mutexes copied from a multithreaded parent.
      # The parent coordinator enforces cancellation and deadlines for fork
      # workers by terminating and reaping the child.
      @execution.checkpoint! if @manager.worker_type == :thread
    end

    def wait_for_retry_delay(delay)
      if @manager.worker_type == :thread
        cancellation = @execution.token.wait_for_cancel(timeout: delay)
        raise cancellation if cancellation
      else
        sleep(delay) if delay.positive?
      end
    end

    def invoke_user_block(block, input, context)
      return block.call(input, context) if @attempt_context_enabled && accepts_attempt_context?(block)
      return block.call if block.lambda? && block.arity.zero?

      block.call(input)
    end

    def accepts_attempt_context?(block)
      parameters = block.parameters.reject { |type, _name| type == :block }
      return false if parameters.empty?

      first_type, first_name = parameters.first
      return true if first_type == :rest && first_name

      parameters.drop(1).any? do |type, name|
        name && %i[req opt rest].include?(type)
      end
    end

    def raise_worker_timeout!
      worker = @manager.timed_out_workers(@id, @worker_timeout).first
      return unless worker

      worker_id = worker.pid.is_a?(Thread) ? worker.pid.object_id : worker.pid
      raise WorkerTimeoutError.new(
        execution_name: @execution.name,
        timeout: @worker_timeout,
        worker_id: worker_id,
        batch_size: worker.batch_size
      )
    end

    def next_wait_timeout
      waits = [
        @execution.remaining_time,
        @manager.time_until_worker_timeout(@id, @worker_timeout)
      ].compact
      waits.empty? ? nil : waits.min
    end

    def get_result(worker)
      if @manager.worker_type == :fork
        get_fork_result(worker)
      else
        get_thread_result(worker)
      end
    end

    def get_fork_result(worker)
      reaped = false
      payload = worker.reader.read
      _pid, status = Process.waitpid2(worker.pid)
      reaped = true
      if payload.empty?
        raise WorkerProcessError,
              "worker #{worker.pid} exited without a result (status #{status.exitstatus || status.termsig})"
      end

      consume_worker_results(Marshal.load(payload))
    ensure
      @manager.stop_worker(worker) unless reaped
      worker.reader.close unless worker.reader.closed?
      @manager.rem_worker(worker)
    end

    def get_thread_result(worker)
      @manager.rem_worker(worker)
      worker.pid.join
      raise worker.error if worker.error

      consume_worker_results(worker.result)
    end

    def consume_worker_results(results)
      # Preserve the historical all-or-fail behavior of one dispatched worker
      # batch: do not expose successful values from that batch before checking
      # whether another item in it failed. This matters most for asynchronous
      # consumers, which could otherwise observe a partial batch before the
      # result queue is aborted.
      raw_error = results.find { |result| result.is_a?(Exception) }
      raise raw_error if raw_error

      failures = results.filter_map do |result|
        result.failure if result.is_a?(WorkOutcome) && result.failure?
      end

      if @failure_mode == :raise && !failures.empty?
        failures.each { |failure| deliver_dead_letter(failure) } if @dead_letter
        raise_work_failure(failures.first)
      end

      results.each do |result|
        if result.is_a?(WorkOutcome)
          if result.success?
            @result.push(result.value, control: @execution)
          else
            deliver_dead_letter(result.failure)
          end
        else
          # Compatibility with workers constructed through the lower-level
          # Manager API instead of Thimble's supervised wrapper.
          @result.push(result, control: @execution)
        end
      end
    end

    def raise_work_failure(failure)
      original = failure.error
      if @structured_failures
        raise WorkFailedError.new(failure), cause: original
      end

      raise original
    end

    def deliver_dead_letter(failure)
      if @dead_letter.is_a?(ThimbleQueue)
        @dead_letter.push(failure, control: @execution)
      else
        deliver_dead_letter_callback(failure)
      end
    rescue StandardError => error
      raise DeadLetterError.new(failure: failure, sink_error: error), cause: error
    end

    def deliver_dead_letter_callback(failure)
      sink_error = nil
      delivery = Thread.new do
        begin
          if @dead_letter.respond_to?(:call)
            @dead_letter.call(failure)
          elsif @dead_letter.respond_to?(:push)
            @dead_letter.push(failure)
          else
            @dead_letter << failure
          end
        rescue Exception => error # rubocop:disable Lint/RescueException -- re-raised by the coordinator
          sink_error = error
        end
      end
      delivery.report_on_exception = false if delivery.respond_to?(:report_on_exception=)
      cancellation = @execution.token.on_cancel do |_error|
        delivery.kill if delivery.alive? && !delivery.equal?(Thread.current)
      end

      remaining = @execution.remaining_time
      remaining ? delivery.join(remaining) : delivery.join
      @execution.checkpoint!
      raise sink_error if sink_error
    ensure
      cancellation&.unsubscribe
      if delivery&.alive? && @execution.token.cancelled?
        delivery.kill
        delivery.join unless delivery.equal?(Thread.current)
      end
    end

    def handle_failure(error)
      effective_error = @execution.token.error || error
      @execution.token.cancel(effective_error) unless @execution.token.cancelled?
      effective_error = @execution.token.error || effective_error

      abort(effective_error) unless closed?
      @result.abort(effective_error) unless @result.closed?
      @manager.signal_change
      stop_source
      @manager.stop_workers(@id)
      @execution.fail!(effective_error) unless @execution.finished?
      release_shutdown_subscription
      effective_error
    end

    def stop_source
      return unless @source_thread
      return if @source_thread.equal?(Thread.current)

      @source_thread.kill if @source_thread.alive?
      @source_thread.join
    end

    def release_shutdown_subscription
      @shutdown_subscription&.unsubscribe
      @shutdown_subscription = nil
    end

    def normalize_failure_mode(value)
      mode = value || :raise
      return mode if FAILURE_MODES.include?(mode)

      raise ArgumentError, 'failure_mode must be :raise or :continue'
    end

    def validate_dead_letter!(sink)
      return nil if sink.nil?
      return sink if sink.respond_to?(:call) || sink.respond_to?(:push) || sink.respond_to?(:<<)

      raise ArgumentError, 'dead_letter must respond to #call, #push, or #<<'
    end

    def validate_timeout_option!(name, value)
      return if value.nil?
      return if value.is_a?(Numeric) && value.positive? && (!value.respond_to?(:finite?) || value.finite?)

      raise ArgumentError, "#{name} must be a finite number greater than 0"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
