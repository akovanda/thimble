# frozen_string_literal: true

require_relative 'supervision'

module Thimble
  class ShutdownTimeoutError < CancelledError
    attr_reader :grace_period

    def initialize(grace_period:)
      @grace_period = grace_period
      super("graceful shutdown exceeded its #{grace_period}-second grace period")
    end
  end

  # Coordinates process signals with one shared CancellationToken. The first
  # signal requests a graceful drain; a repeated signal or an expired grace
  # period escalates to immediate cancellation.
  class ShutdownCoordinator
    DEFAULT_SIGNALS = %w[INT TERM].freeze
    MONITOR_INTERVAL = 0.05

    attr_reader :token, :signals, :grace_period

    def initialize(token: CancellationToken.new, signals: DEFAULT_SIGNALS, grace_period: 10.0)
      unless token.is_a?(CancellationToken)
        raise ArgumentError, 'token must be a Thimble::CancellationToken'
      end

      validate_grace_period!(grace_period)
      @token = token
      @signals = normalize_signals(signals)
      @grace_period = grace_period&.to_f
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @targets = []
      @notification_count = 0
      @closed = false
      @installed = false
      @reader = nil
      @writer = nil
      @reader_thread = nil
      @escalation_thread = nil
      @previous_handlers = {}
      @signal_by_code = {}
    end

    def register(*targets)
      executions = targets.flatten.map { |target| normalize_execution(target) }
      @mutex.synchronize do
        raise RuntimeError, 'shutdown coordinator is closed' if @closed
        if token.shutdown?
          raise RuntimeError, 'cannot register executions after shutdown has begun'
        end

        executions.each do |execution|
          @targets << execution unless @targets.include?(execution)
        end
        @condition.broadcast
      end
      self
    end

    def install
      ensure_main_thread!('install')
      @mutex.synchronize do
        raise RuntimeError, 'shutdown coordinator is closed' if @closed
        return self if @installed

        @reader, @writer = IO.pipe
        @signal_by_code = signals.each_with_index.to_h { |signal, index| [(index + 1).chr, signal] }
        @installed = true
      end

      @reader_thread = Thread.new { read_signals }
      install_signal_handlers
      self
    rescue Exception # rubocop:disable Lint/RescueException -- restore partial process signal state
      close_internal(restore_handlers: true)
      raise
    end

    alias install! install

    def installed?
      @mutex.synchronize { @installed }
    end

    # Public for embedders and deterministic tests. +signal+ may be "TERM",
    # "SIGTERM", or a symbol.
    def notify(signal)
      normalized = normalize_signal(signal)
      unless signals.include?(normalized)
        raise ArgumentError, "signal SIG#{normalized} is not configured for this coordinator"
      end

      count = @mutex.synchronize do
        return false if @closed

        @notification_count += 1
      end

      if count == 1 && !token.shutdown?
        changed = token.drain("received SIG#{normalized}")
        start_escalation_timer if changed
        changed
      else
        token.cancel("received SIG#{normalized} during graceful shutdown")
      end
    end

    def close
      ensure_main_thread!('close') if installed?
      close_internal(restore_handlers: true)
      self
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    def targets_finished?
      targets = @mutex.synchronize { @targets.dup }
      !targets.empty? && targets.all?(&:finished?)
    end

    private

    def install_signal_handlers
      signals.each_with_index do |signal, index|
        writer = @writer
        payload = (index + 1).chr.freeze
        previous = Signal.trap(signal) do
          begin
            writer.write_nonblock(payload)
          rescue IO::WaitWritable, Errno::EAGAIN, IOError
            # The coordinator is already waking or closing; dropping a duplicate
            # byte is safe because a repeated signal still reaches the shared
            # cancellation token through the next successful notification.
            nil
          end
        end
        @previous_handlers[signal] = previous
      end
    end

    def read_signals
      loop do
        code = @reader.read(1)
        break unless code

        signal = @signal_by_code[code]
        notify(signal) if signal
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def start_escalation_timer
      return unless grace_period

      @mutex.synchronize do
        return if @escalation_thread&.alive?

        @escalation_thread = Thread.new do
          deadline = monotonic_now + grace_period
          loop do
            break if closed? || token.cancelled? || targets_finished?

            remaining = deadline - monotonic_now
            if remaining <= 0
              token.cancel(ShutdownTimeoutError.new(grace_period: grace_period))
              break
            end

            @mutex.synchronize do
              break if @closed

              @condition.wait(@mutex, [remaining, MONITOR_INTERVAL].min)
            end
          end
        end
      end
    end

    def close_internal(restore_handlers:)
      handlers = nil
      reader_thread = nil
      escalation_thread = nil
      reader = nil
      writer = nil

      @mutex.synchronize do
        return if @closed

        @closed = true
        @installed = false
        handlers = @previous_handlers.dup
        @previous_handlers.clear
        reader_thread = @reader_thread
        escalation_thread = @escalation_thread
        reader = @reader
        writer = @writer
        @reader_thread = nil
        @escalation_thread = nil
        @reader = nil
        @writer = nil
        @condition.broadcast
      end

      if restore_handlers
        handlers.each { |signal, handler| Signal.trap(signal, handler) }
      end
      writer&.close unless writer&.closed?
      reader&.close unless reader&.closed?
      reader_thread&.join unless reader_thread&.equal?(Thread.current)
      escalation_thread&.join unless escalation_thread&.equal?(Thread.current)
    end

    def normalize_execution(target)
      execution = target.is_a?(Execution) ? target : target.respond_to?(:execution) ? target.execution : nil
      return execution if execution.is_a?(Execution)

      raise ArgumentError, 'registered targets must be a Thimble::Execution or expose #execution'
    end

    def normalize_signals(values)
      normalized = Array(values).map { |signal| normalize_signal(signal) }.uniq
      raise ArgumentError, 'signals must contain at least one signal' if normalized.empty?

      available = Signal.list
      unknown = normalized.reject { |signal| available.key?(signal) }
      unless unknown.empty?
        raise ArgumentError, "unsupported signal(s): #{unknown.join(', ')}"
      end
      normalized.freeze
    end

    def normalize_signal(signal)
      normalized = signal.to_s.upcase.sub(/\ASIG/, '')
      raise ArgumentError, 'signal must not be empty' if normalized.empty?

      normalized
    end

    def validate_grace_period!(value)
      return if value.nil?
      return if value.is_a?(Numeric) && value.positive? && (!value.respond_to?(:finite?) || value.finite?)

      raise ArgumentError, 'grace_period must be a finite number greater than 0 or nil'
    end

    def ensure_main_thread!(operation)
      return if Thread.current.equal?(Thread.main)

      raise ThreadError, "ShutdownCoordinator##{operation} must run on the main thread"
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
