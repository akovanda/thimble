
require_relative 'Manager'
require_relative 'ThimbleQueue'
require_relative 'QueueItem'
require 'io/wait'
require 'ostruct'

module Thimble

  class Thimble < ThimbleQueue
    def initialize(array, manager = Manager.new)
      raise ArgumentError.new ("You need to pass a manager to Thimble!") unless manager.class == Manager
      raise ArgumentError.new ("There needs to be an iterable object passed to Thimble to start.") unless array.respond_to? :each
      @manager = manager
      @result = ThimbleQueue.new(array.size, "Result")
      @running = true
      super(array.size, "Main")
      array.each {|item| push(item)}
      close()
    end

    # requires a block
    def par_map
      @running = true
      while @running
        manage_workers &Proc.new
      end
      @result.close()
      @result
    end

    # Will perform anything handed to this asynchronously. 
    # Requires a block
    def self.a_sync
      Thread.new do |e|
        yield e
      end
    end

    private
    def get_batch
      batch = []
      while batch.size < @manager.batch_size
        item = self.next
        if item.nil?
          return nil if batch.size == 0
          return QueueItem.new(batch, "Batch")
        else
          batch << item
        end
      end
      QueueItem.new(batch, "Batch")
    end

    def manage_workers
      while (@manager.worker_available? && batch = get_batch)
        @manager.sub_worker( @manager.get_worker(batch, &Proc.new), @id)
      end
      @manager.current_workers(@id).each do |pid, pair|
        get_result(pair.worker)
      end
      @running = false if !@manager.working? && !batch
    end

    def get_result(tuple)
      if @manager.worker_type == :fork
        if tuple.reader.ready?
          piped_result = tuple.reader.read
          loadedResult = Marshal.load(piped_result)
          loadedResult.each { |r| raise r if r.class <= Exception }
          push_result(loadedResult)
          Process.kill("HUP", tuple.pid)
          @manager.rem_worker(tuple)
        end
      else
        if tuple.done == true
          push_result(tuple.result)
          @manager.rem_worker(tuple)
        end
      end
    end

    def push_result(result)
      if result.respond_to? :each
        result.each {|r| @result.push(r)}
      else
        @result.push(result)
      end
    end
  end
end
