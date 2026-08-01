# frozen_string_literal: true

require_relative 'supervision'

module Thimble
  class RemoteWorkerError < RuntimeError
    attr_reader :remote_class

    def initialize(remote_class:, message:, backtrace: nil)
      @remote_class = remote_class
      super("#{remote_class}: #{message}")
      set_backtrace(backtrace) if backtrace
    end
  end

  class PayloadSnapshot
    MAX_SUMMARY_LENGTH = 500

    attr_reader :value, :class_name, :summary

    def self.capture(value, preserve_unmarshalable: false)
      available = preserve_unmarshalable || marshalable?(value)
      new(
        value: available ? value : nil,
        class_name: value.class.name || value.class.to_s,
        summary: summarize(value),
        available: available
      )
    end

    def self.marshalable?(value)
      Marshal.dump(value)
      true
    rescue StandardError
      false
    end

    def self.summarize(value)
      summary = value.inspect
      summary = "#{summary[0, MAX_SUMMARY_LENGTH]}…" if summary.length > MAX_SUMMARY_LENGTH
      summary
    rescue StandardError => error
      "<inspect failed: #{error.class}: #{error.message}>"
    end

    def initialize(value:, class_name:, summary:, available:)
      @value = value
      @class_name = class_name
      @summary = summary
      @available = available
    end

    def available?
      @available
    end
  end

  class ErrorSnapshot
    attr_reader :class_name, :message, :backtrace

    def self.capture(error, preserve_unmarshalable: false)
      available = preserve_unmarshalable || PayloadSnapshot.marshalable?(error)
      new(
        original: available ? error : nil,
        class_name: error.class.name || error.class.to_s,
        message: safe_message(error),
        backtrace: safe_backtrace(error),
        available: available
      )
    end

    def self.safe_message(error)
      error.message.to_s
    rescue StandardError => message_error
      "<message failed: #{message_error.class}: #{message_error.message}>"
    end

    def self.safe_backtrace(error)
      error.backtrace
    rescue StandardError
      nil
    end

    def initialize(original:, class_name:, message:, backtrace:, available:)
      @original = original
      @class_name = class_name
      @message = message
      @backtrace = backtrace
      @available = available
    end

    def available?
      @available
    end

    def exception
      return @original if @original

      RemoteWorkerError.new(remote_class: class_name, message: message, backtrace: backtrace)
    end
  end

  class AttemptContext
    attr_reader :execution_name, :attempt, :max_attempts, :input, :batch_mode,
                :batch_size, :worker_type, :worker_id, :started_at

    def initialize(execution_name:, attempt:, max_attempts:, input:, batch_mode:,
                   batch_size:, worker_type:, worker_id:, started_at:)
      @execution_name = execution_name
      @attempt = attempt
      @max_attempts = max_attempts
      @input = input
      @batch_mode = batch_mode
      @batch_size = batch_size
      @worker_type = worker_type
      @worker_id = worker_id
      @started_at = started_at
    end

    def batch?
      batch_mode
    end

    def first_attempt?
      attempt == 1
    end

    def final_attempt?
      attempt >= max_attempts
    end
  end

  class FailureContext
    attr_reader :execution_name, :payload, :attempt, :max_attempts, :error_snapshot,
                :retryable, :exhausted, :batch_mode, :batch_size, :worker_type,
                :worker_id, :started_at, :failed_at, :elapsed

    def initialize(execution_name:, payload:, attempt:, max_attempts:, error_snapshot:,
                   retryable:, exhausted:, batch_mode:, batch_size:, worker_type:,
                   worker_id:, started_at:, failed_at:, elapsed:)
      @execution_name = execution_name
      @payload = payload
      @attempt = attempt
      @max_attempts = max_attempts
      @error_snapshot = error_snapshot
      @retryable = retryable
      @exhausted = exhausted
      @batch_mode = batch_mode
      @batch_size = batch_size
      @worker_type = worker_type
      @worker_id = worker_id
      @started_at = started_at
      @failed_at = failed_at
      @elapsed = elapsed
    end

    def input
      payload.value
    end

    def input_available?
      payload.available?
    end

    def input_class
      payload.class_name
    end

    def input_summary
      payload.summary
    end

    def error
      error_snapshot.exception
    end

    def original_error_available?
      error_snapshot.available?
    end

    def batch?
      batch_mode
    end

    def retryable?
      retryable
    end

    def exhausted?
      exhausted
    end

    def classification
      return :retry_exhausted if retryable? && exhausted?

      :non_retryable
    end
  end

  class WorkOutcome
    attr_reader :value, :failure

    def self.success(value)
      new(value: value)
    end

    def self.failure(failure)
      new(failure: failure)
    end

    def initialize(value: nil, failure: nil)
      @value = value
      @failure = failure
    end

    def success?
      failure.nil?
    end

    def failure?
      !success?
    end
  end

  class WorkFailedError < RuntimeError
    attr_reader :failure

    def initialize(failure)
      @failure = failure
      super(
        "#{failure.execution_name} failed after #{failure.attempt}/#{failure.max_attempts} " \
        "attempt(s): #{failure.error_snapshot.class_name}: #{failure.error_snapshot.message}"
      )
    end
  end

  class DeadLetterError < RuntimeError
    attr_reader :failure, :sink_error

    def initialize(failure:, sink_error:)
      @failure = failure
      @sink_error = sink_error
      super(
        "dead-letter delivery failed for #{failure.execution_name}: " \
        "#{sink_error.class}: #{sink_error.message}"
      )
    end
  end

  class RetryPolicy
    DEFAULT_ABORT_ON = [ArgumentError, TypeError, NameError, LocalJumpError, FrozenError, ZeroDivisionError].freeze

    attr_reader :max_attempts, :base_delay, :max_delay, :multiplier, :jitter

    def self.coerce(value)
      case value
      when nil
        new(max_attempts: 1)
      when RetryPolicy
        value
      when Integer
        new(max_attempts: value)
      when Hash
        new(**value.transform_keys(&:to_sym))
      else
        raise ArgumentError, 'retry_policy must be a Thimble::RetryPolicy, Integer, Hash, or nil'
      end
    end

    def initialize(max_attempts:, base_delay: 0.0, max_delay: 30.0, multiplier: 2.0,
                   jitter: 0.0, retry_on: StandardError, abort_on: DEFAULT_ABORT_ON)
      validate_positive_integer!(:max_attempts, max_attempts)
      validate_nonnegative_number!(:base_delay, base_delay)
      validate_nonnegative_number!(:max_delay, max_delay)
      validate_number!(:multiplier, multiplier) { |value| value >= 1.0 }
      validate_number!(:jitter, jitter) { |value| value.between?(0.0, 1.0) }
      raise ArgumentError, 'max_delay must be greater than or equal to base_delay' if max_delay < base_delay

      @max_attempts = max_attempts
      @base_delay = base_delay.to_f
      @max_delay = max_delay.to_f
      @multiplier = multiplier.to_f
      @jitter = jitter.to_f
      @retry_matchers = normalize_matchers(retry_on, :retry_on)
      @abort_matchers = normalize_matchers(abort_on, :abort_on)
      freeze
    end

    def retryable?(error, context = nil)
      return false if error.is_a?(CancelledError)
      return false if matches_any?(@abort_matchers, error, context)

      matches_any?(@retry_matchers, error, context)
    end

    # +failed_attempt+ is the attempt that just failed. The returned delay is
    # used before the next attempt and is always bounded by +max_delay+.
    def delay_for(failed_attempt, random: Random)
      validate_positive_integer!(:failed_attempt, failed_attempt)
      unless random.respond_to?(:rand)
        raise ArgumentError, 'random must respond to #rand'
      end

      uncapped = base_delay * (multiplier**(failed_attempt - 1))
      capped = [uncapped, max_delay].min
      return capped if jitter.zero? || capped.zero?

      factor = 1.0 - jitter + (2.0 * jitter * random.rand)
      [[capped * factor, 0.0].max, max_delay].min
    end

    private

    def normalize_matchers(value, name)
      values = value.nil? ? [] : Array(value)
      values.each do |matcher|
        next if matcher.respond_to?(:call)
        next if matcher.is_a?(Class) && matcher <= Exception

        raise ArgumentError, "#{name} entries must be exception classes or callables"
      end
      values.freeze
    end

    def matches_any?(matchers, error, context)
      matchers.any? do |matcher|
        if matcher.respond_to?(:call)
          invoke_matcher(matcher, error, context)
        else
          error.is_a?(matcher)
        end
      end
    end

    def invoke_matcher(matcher, error, context)
      if matcher.respond_to?(:lambda?) && matcher.lambda? && matcher.arity == 1
        matcher.call(error)
      elsif matcher.respond_to?(:arity) && matcher.arity == 1
        matcher.call(error)
      else
        matcher.call(error, context)
      end
    end

    def validate_positive_integer!(name, value)
      return if value.is_a?(Integer) && value.positive?

      raise ArgumentError, "#{name} must be an integer greater than 0"
    end

    def validate_nonnegative_number!(name, value)
      validate_number!(name, value) { |candidate| candidate >= 0 }
    end

    def validate_number!(name, value)
      valid = value.is_a?(Numeric) && (!value.respond_to?(:finite?) || value.finite?)
      valid &&= yield(value.to_f) if valid && block_given?
      return if valid

      raise ArgumentError, "#{name} is invalid"
    end
  end
end
