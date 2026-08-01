# frozen_string_literal: true

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
      @started = false
      super(@manager.queue_size, name)
    end

    # Transforms each item and returns a result queue after all work finishes.
    def map(&block)
      start_sync(:map, batch_mode: false, &block)
    end

    # Sends each worker one array of up to Manager#batch_size items. This is
    # useful for bulk APIs, database writes, and other amortized operations.
    def map_batches(&block)
      start_sync(:map_batches, batch_mode: true, &block)
    end

    # Runs #map in a coordinator thread and returns a bounded result queue
    # immediately. Consuming the result provides downstream backpressure.
    def map_async(&block)
      start_async(:map_async, batch_mode: false, &block)
    end

    # Asynchronous form of #map_batches.
    def map_batches_async(&block)
      start_async(:map_batches_async, batch_mode: true, &block)
    end

    def self.async(&block)
      Thread.new(&block)
    end

    private

    def start_sync(method_name, batch_mode:, &block)
      validate_start!(method_name, block)
      capacity = sync_result_capacity
      @started = true
      ensure_result(capacity)
      start_source
      run_map(batch_mode: batch_mode, &block)
    end

    def start_async(method_name, batch_mode:, &block)
      validate_start!(method_name, block)
      @started = true
      ensure_result(@manager.queue_size)
      start_source
      Thimble.async do
        run_map(batch_mode: batch_mode, &block)
      rescue Exception # rubocop:disable Lint/RescueException -- result queue already carries the failure
        nil
      end
      @result
    end

    def validate_start!(method_name, block)
      raise ArgumentError, "#{method_name} requires a block" unless block
      raise RuntimeError, 'this Thimble has already been consumed' if @started
    end

    def start_source
      @source_thread = Thread.new do
        begin
          @source.each { |item| push(item) }
          close
        rescue Exception => error # rubocop:disable Lint/RescueException -- propagate source failures through the queue
          abort(error) unless aborted?
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
        @manager.completed_workers(@id).each { |worker| get_result(worker) }

        until input_exhausted || !@manager.worker_available?
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

        @manager.wait_for_change(@id, wait_for_capacity: !input_exhausted)
      end

      @source_thread.join
      @result.close
      @result
    rescue Exception => error # rubocop:disable Lint/RescueException -- preserve worker failures and interrupts
      abort(error) unless closed?
      @source_thread.join
      @manager.stop_workers(@id)
      @result.abort(error) unless @result.closed?
      raise
    end

    def get_batch
      batch = []
      while batch.size < @manager.batch_size
        item = self.next
        if item.nil?
          return nil if batch.empty?

          return QueueItem.new(batch, 'Batch')
        end
        batch << item
      end
      QueueItem.new(batch, 'Batch')
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
        result.each { |item| @result.push(item) }
      else
        @result.push(result)
      end
    end
  end
end
