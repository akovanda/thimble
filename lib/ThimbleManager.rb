module Thimble
  class ThimbleManager
    attr_reader :max_workers, :batch_size, :queue_size, :worker_type, :current_workers
    def initialize(max_workers: 6,batch_size: 1000, queue_size: 1000, worker_type: :fork)
      raise ArgumentError.new ("worker type must be either :fork or :thread") unless worker_type == :thread || worker_type == :fork
      raise ArgumentError.new ("Your system does not respond to fork please use threads.") unless worker_type == :thread || Process.respond_to?(:fork)
      raise ArgumentError.new ("max_workers must be greater than 0") if max_workers < 1
      raise ArgumentError.new ("batch size must be greater than 0") if batch_size < 1
      @worker_type = worker_type
      @max_workers = max_workers
      @batch_size = batch_size
      @queue_size = queue_size
      @current_workers = []
    end

    def worker_available?
      @current_workers.size < @max_workers
    end

    def working?
      @current_workers.size > 0
    end

    def sub_worker(worker)
      raise "Worker must contain a pid!" if worker.pid.nil?
      @current_workers << worker
    end

    def rem_worker(worker)
      @current_workers.delete(worker)
    end

    def get_worker (batch)
      if @worker_type == :fork
        get_fork_worker(batch, &Proc.new)    
      else
        get_thread_worker(batch, &Proc.new)
      end
    end

    def get_fork_worker(batch)
      rd, wr = IO.pipe
      tup = OpenStruct.new
      pid = fork do
        Signal.trap("HUP") {exit}
        rd.close 
        t = Marshal.dump(batch.item.map do |item|
          yield (item.item)
        end)
        wr.write(t)
        wr.close
      end
      wr.close
      tup.pid = pid
      tup.reader = rd
      tup
    end

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

    def self.deterministic
      self.new(max_workers: 1, batch_size: 1, queue_size: 1)
    end

    def self.small
      self.new(max_workers: 1, batch_size: 3, queue_size: 3)
    end
  end
end