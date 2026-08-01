# frozen_string_literal: true

require_relative 'supervision'
require_relative 'manager'
require_relative 'thimble_queue'
require_relative 'queue_item'
require_relative 'thimble/version'

module Thimble
  class Thimble < ThimbleQueue
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
      @source_thread = nil
      @coordinator_thread = nil
      @cancel_subscription = nil
      @worker_timeout = nil
      @started = false
      super(@manager.queue_size, name)
    end

    # Transforms each item and returns a result queue after all work finishes.
    def map(timeout: nil, worker_timeout: nil, cancellation: nil, &block)
      start_sync(
        :map,
        batch_mode: false,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        &block
      )
    end

    # Sends each worker one array of up to Manager#batch_size items. This is
    # useful for bulk APIs, database writes, and other amortized operations.
    def map_batches(timeout: nil, worker_timeout: nil, cancellation: nil, &block)
      start_sync(
        :map_batches,
        batch_mode: true,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        &block
      )
    end

    # Runs #map in a coordinator thread and returns a bounded result queue
    # immediately. Consuming the result provides downstream backpressure.
    def map_async(timeout: nil, worker_timeout: nil, cancellation: nil, &block)
      start_async(
        :map_async,
        batch_mode: false,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        &block
      )
    end

    # Asynchronous form of #map_batches.
    def map_batches_async(timeout: nil, worker_timeout: nil, cancellation: nil, &block)
      start_async(
        :map_batches_async,
        batch_mode: true,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation,
        &block
      )
    end

    def self.async(&block)
      Thread.new(&block)
    end

    private

    def start_sync(method_name, batch_mode:, timeout:, worker_timeout:, cancellation:, &block)
      validate_start!(method_name, block)
      capacity = sync_result_capacity
      prepare_execution(
        method_name,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation
      )
      @started = true
      ensure_result(capacity)
      attach_execution_queues
      install_cancel_handler

      begin
        @execution.start!
        start_source
        run_map(batch_mode: batch_mode, &block)
      rescue Exception => error # rubocop:disable Lint/RescueException -- preserve cancellation and interrupts
        effective_error = handle_failure(error)
        raise effective_error
      end
    end

    def start_async(method_name, batch_mode:, timeout:, worker_timeout:, cancellation:, &block)
      validate_start!(method_name, block)
      prepare_execution(
        method_name,
        timeout: timeout,
        worker_timeout: worker_timeout,
        cancellation: cancellation
      )
      @started = true
      ensure_result(@manager.queue_size)
      attach_execution_queues
      install_cancel_handler

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

    def prepare_execution(method_name, timeout:, worker_timeout:, cancellation:)
      validate_timeout_option!(:worker_timeout, worker_timeout)
      token = cancellation || CancellationToken.new
      unless token.is_a?(CancellationToken)
        raise ArgumentError, 'cancellation must be a Thimble::CancellationToken'
      end

      @worker_timeout = worker_timeout
      @execution = Execution.new(name: "#{@name}.#{method_name}", timeout: timeout, token: token)
    end

    def attach_execution_queues
      attach_execution(@execution)
      @result.attach_execution(@execution)
    end

    def install_cancel_handler
      @cancel_subscription = @execution.token.on_cancel do |error|
        next if @execution.finished?

        abort(error) unless closed?
        @result.abort(error) unless @result.closed?
        @manager.signal_change
      end
    end

    def start_source
      @source_thread = Thread.new do
        begin
          @source.each do |item|
            @execution.checkpoint!
            push(item, control: @execution)
          end
          close unless closed?
        rescue Exception => error # rubocop:disable Lint/RescueException -- source failures propagate through the queue
          abort(error) unless closed?
          @manager.signal_change
        end
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

          worker = @manager.start_worker(pending_batch, @id, batch_mode: batch_mode, &block)
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
      release_cancel_subscription
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

      loaded_result = Marshal.load(payload)
      loaded_result.each { |result| raise result if result.is_a?(Exception) }
      push_result(loaded_result)
    ensure
      @manager.stop_worker(worker) unless reaped
      worker.reader.close unless worker.reader.closed?
      @manager.rem_worker(worker)
    end

    def get_thread_result(worker)
      @manager.rem_worker(worker)
      worker.pid.join
      raise worker.error if worker.error
      worker.result.each { |result| raise result if result.is_a?(Exception) }

      push_result(worker.result)
    end

    def push_result(result)
      if result.respond_to?(:each)
        result.each { |item| @result.push(item, control: @execution) }
      else
        @result.push(result, control: @execution)
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
      release_cancel_subscription
      effective_error
    end

    def stop_source
      return unless @source_thread
      return if @source_thread.equal?(Thread.current)

      @source_thread.kill if @source_thread.alive?
      @source_thread.join
    end

    def release_cancel_subscription
      @cancel_subscription&.unsubscribe
      @cancel_subscription = nil
    end

    def validate_timeout_option!(name, value)
      return if value.nil?
      return if value.is_a?(Numeric) && value.positive? && (!value.respond_to?(:finite?) || value.finite?)

      raise ArgumentError, "#{name} must be a finite number greater than 0"
    end
  end
end
