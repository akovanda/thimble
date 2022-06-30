# frozen_string_literal: true

Thread.abort_on_exception = true

module Thimble
  class Manager
    attr_reader :max_workers, :batch_size, :queue_size, :worker_type

    def initialize(max_workers: 6, batch_size: 1000, queue_size: 1000, worker_type: :fork)
      raise ArgumentError, 'worker type must be either :fork or :thread' unless %i[thread fork].include?(worker_type)
      unless worker_type == :thread || Process.respond_to?(:fork)
        raise ArgumentError, 'Your system does not respond to fork please use threads.'
      end
      raise ArgumentError, 'max_workers must be greater than 0' if max_workers < 1
      raise ArgumentError, 'batch size must be greater than 0' if batch_size < 1

      @worker_type = worker_type
      @max_workers = max_workers
      @batch_size = batch_size
      @queue_size = queue_size
      @mutex = Mutex.new
      @current_workers = {}
    end

    # @return [TrueClass, FalseClass]
    def worker_available?
      @current_workers.size < @max_workers
    end

    # @return [TrueClass, FalseClass]
    def working?
      @current_workers.size.positive?
    end

    # @param [Object] id
    def sub_worker(worker, id)
      raise 'Worker must contain a pid!' if worker.pid.nil?

      new_worker = OpenStruct.new
      new_worker.worker = worker
      new_worker.id = id
      @mutex.synchronize do
        @current_workers[worker.pid] = new_worker
      end
    end

    # @param [Object] worker
    def rem_worker(worker)
      @mutex.synchronize do
        @current_workers.delete(worker.pid)
      end
    end

    # @param [Object] id
    def current_workers(id)
      @mutex.synchronize do
        @current_workers.select { |_k, v| v.id == id }
      end
    end

    # @param [Object] batch
    # @param [Proc] block
    # @return [Object]
    def get_worker(batch, &block)
      @mutex.synchronize do
        if @worker_type == :fork
          get_fork_worker(batch, &block)
        else
          get_thread_worker(batch, &block)
        end
      end
    end

    # @param [Object] batch
    def get_fork_worker(batch)
      rd, wr = IO.pipe
      tup = OpenStruct.new
      pid = fork do
        Signal.trap('HUP') { exit }
        rd.close
        t = Marshal.dump(batch.item.map do |item|
          yield item.item
        rescue Exception => e
          e
        end)
        wr.write(t)
        wr.close
      end
      wr.close
      tup.pid = pid
      tup.reader = rd
      tup
    end

    # @param [Object] batch
    # @param [Proc] block
    def get_thread_worker(batch)
      tup = OpenStruct.new
      tup.pid = Thread.new do
        tup.result = batch.item.map do |item|
          yield item.item
        end
        tup.done = true
      end
      tup
    end

    # @return [Thimble::Manager]
    def self.deterministic
      new(max_workers: 1, batch_size: 1, queue_size: 1)
    end

    # @return [Thimble::Manager]
    def self.small
      new(max_workers: 1, batch_size: 3, queue_size: 3)
    end
  end
end
