# frozen_string_literal: true

module Thimble
  class WorkerProcessError < RuntimeError; end

  Worker = Struct.new(:pid, :reader, :result, :error, :done, keyword_init: true)
  WorkerRegistration = Struct.new(:worker, :id, keyword_init: true)

  class Manager
    attr_reader :max_workers, :batch_size, :queue_size, :worker_type

    def initialize(max_workers: 6, batch_size: 1000, queue_size: 1000, worker_type: :fork)
      raise ArgumentError, 'worker type must be either :fork or :thread' unless %i[thread fork].include?(worker_type)
      if worker_type == :fork && !Process.respond_to?(:fork)
        raise ArgumentError, 'Your system does not respond to fork; please use threads.'
      end

      validate_positive_integer!(:max_workers, max_workers)
      validate_positive_integer!(:batch_size, batch_size)
      validate_positive_integer!(:queue_size, queue_size)

      @worker_type = worker_type
      @max_workers = max_workers
      @batch_size = batch_size
      @queue_size = queue_size
      @mutex = Mutex.new
      @condition = ConditionVariable.new
      @current_workers = {}
      @reserved_workers = 0
    end

    def worker_available?
      @mutex.synchronize { worker_available_unlocked? }
    end

    def working?
      @mutex.synchronize { working_unlocked? }
    end

    def working_for?(id)
      @mutex.synchronize { working_for_unlocked?(id) }
    end

    # Atomically reserves capacity, starts a worker, and registers it.
    # Returns nil if another pipeline has already consumed the final slot.
    def start_worker(batch, id, batch_mode: false, &block)
      reservation_active = @mutex.synchronize do
        next false unless worker_available_unlocked?

        @reserved_workers += 1
        true
      end
      return nil unless reservation_active

      worker = get_worker(batch, batch_mode: batch_mode, &block)
      @mutex.synchronize do
        @reserved_workers -= 1
        reservation_active = false
        @current_workers[worker.pid] = WorkerRegistration.new(worker: worker, id: id)
        @condition.broadcast
      end
      worker
    rescue Exception # rubocop:disable Lint/RescueException -- release reservation before preserving caller semantics
      @mutex.synchronize do
        if reservation_active
          @reserved_workers -= 1
          reservation_active = false
        end
        @condition.broadcast
      end
      raise
    end

    # Compatibility method for callers that construct and register separately.
    def sub_worker(worker, id)
      raise 'Worker must contain a pid!' if worker.pid.nil?

      @mutex.synchronize do
        @current_workers[worker.pid] = WorkerRegistration.new(worker: worker, id: id)
        @condition.broadcast
      end
      worker
    end

    def rem_worker(worker)
      @mutex.synchronize do
        removed = @current_workers.delete(worker.pid)
        @condition.broadcast if removed
        removed
      end
    end

    def current_workers(id)
      @mutex.synchronize do
        @current_workers.select { |_key, registration| registration.id == id }
      end
    end

    def completed_workers(id)
      registrations = current_workers(id).values
      return registrations.filter_map { |entry| entry.worker if entry.worker.done } if @worker_type == :thread

      readers = registrations.filter_map { |entry| entry.worker.reader unless entry.worker.reader.closed? }
      ready_readers = IO.select(readers, nil, nil, 0)&.first || []
      registrations.filter_map do |entry|
        worker = entry.worker
        worker if ready_readers.include?(worker.reader)
      end
    end

    # Blocks until this pipeline can make progress: one of its workers finishes,
    # a shared worker slot opens, or it has no remaining workers.
    def wait_for_change(id, wait_for_capacity: true)
      return if wait_for_capacity && worker_available?

      if @worker_type == :fork
        readers = current_workers(id).values.filter_map do |entry|
          entry.worker.reader unless entry.worker.reader.closed?
        end
        return IO.select(readers, nil, nil, 0.1) unless readers.empty?
      end

      @mutex.synchronize do
        until (wait_for_capacity && worker_available_unlocked?) ||
              completed_worker_unlocked?(id) ||
              (!wait_for_capacity && !working_for_unlocked?(id))
          @condition.wait(@mutex)
        end
      end
    end

    def get_worker(batch, batch_mode: false, &block)
      if @worker_type == :fork
        get_fork_worker(batch, batch_mode: batch_mode, &block)
      else
        get_thread_worker(batch, batch_mode: batch_mode, &block)
      end
    end

    def get_fork_worker(batch, batch_mode: false)
      reader, writer = IO.pipe
      pid = fork do
        reader.close
        begin
          results = execute_batch(batch, batch_mode) { |value| yield value }
          write_marshaled(writer, results)
        rescue StandardError => error
          write_marshaled(writer, [error])
        ensure
          writer.close unless writer.closed?
        end
        exit! 0
      end
      writer.close
      Worker.new(pid: pid, reader: reader, done: false)
    end

    def get_thread_worker(batch, batch_mode: false)
      worker = Worker.new(done: false)
      worker.pid = Thread.new do
        begin
          worker.result = execute_batch(batch, batch_mode) { |value| yield value }
        rescue Exception => error # rubocop:disable Lint/RescueException -- propagated by Thimble#get_result
          worker.error = error
        ensure
          mark_completed(worker)
        end
      end
      worker
    end

    def stop_worker(worker)
      if @worker_type == :thread
        worker.pid.kill if worker.pid.alive?
        worker.pid.join
      else
        terminate_process(worker.pid)
        worker.reader.close unless worker.reader.closed?
      end
      worker
    end

    def stop_workers(id)
      current_workers(id).each_value do |registration|
        worker = registration.worker
        stop_worker(worker)
      ensure
        rem_worker(worker) if worker
      end
    end

    def self.deterministic
      new(max_workers: 1, batch_size: 1, queue_size: 1)
    end

    def self.small
      new(max_workers: 1, batch_size: 3, queue_size: 3)
    end

    private

    def validate_positive_integer!(name, value)
      return if value.is_a?(Integer) && value.positive?

      raise ArgumentError, "#{name} must be an integer greater than 0"
    end

    def worker_available_unlocked?
      @current_workers.size + @reserved_workers < @max_workers
    end

    def working_unlocked?
      @current_workers.any? || @reserved_workers.positive?
    end

    def working_for_unlocked?(id)
      @current_workers.any? { |_key, registration| registration.id == id }
    end

    def completed_worker_unlocked?(id)
      @current_workers.any? do |_key, registration|
        registration.id == id && registration.worker.done
      end
    end

    def mark_completed(worker)
      @mutex.synchronize do
        worker.done = true
        @condition.broadcast
      end
    end

    def execute_batch(batch, batch_mode)
      values = batch.item.map(&:item)
      return [yield(values)] if batch_mode

      values.map do |value|
        yield value
      rescue StandardError => error
        error
      end
    end

    def write_marshaled(writer, value)
      writer.write(Marshal.dump(value))
    rescue StandardError => marshal_error
      fallback = RuntimeError.new("worker result could not be marshaled: #{marshal_error.class}: #{marshal_error.message}")
      writer.write(Marshal.dump([fallback]))
    end

    def terminate_process(pid)
      Process.kill('TERM', pid)
    rescue Errno::ESRCH
      nil
    ensure
      begin
        Process.waitpid(pid)
      rescue Errno::ECHILD
        nil
      end
    end
  end
end
