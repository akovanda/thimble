
require_relative 'Manager'
require_relative 'ThimbleQueue'
require_relative 'QueueItem'
require 'io/wait'
require 'ostruct'

module Thimble

  class Thimble < ThimbleQueue
    def initialize(array, manager = Manager.new, result = nil, name = "Main")
      raise ArgumentError.new ("You need to pass a manager to Thimble!") unless manager.class == Manager
      raise ArgumentError.new ("There needs to be an iterable object passed to Thimble to start.") unless array.respond_to? :each
      @result = if result.nil?
        ThimbleQueue.new(array.size, "Result")
      else
        result
      end
      raise ArgumentError.new ("result needs to be an open ThimbleQueue") unless (@result.class == ThimbleQueue && !@result.closed?)
      @manager = manager
      @running = true
      super(array.size, name)
      @logger.debug("loading thimble #{name}")
      array.each {|item| push(item)}
      @logger.debug("finished loading thimble #{name}")
      close()
    end

    # This will use the manager and transform your thimble queue.
    # requires a block 
    # @return [ThimbleQueue]
    def map
      @logger.debug("starting map in #{@name} with id #{Thread.current.object_id}")
      @running = true
      while @running
        manage_workers &Proc.new
      end
      @result.close()
      @logger.debug("finishing map in #{@name} with id #{Thread.current.object_id}")
      @result
    end

    # This will use the manager and transform the thimble queue asynchronously.
    # Will return the result instantly, so you can use it for next stage processing.
    # requires a block
    # @return [ThimbleQueue]
    def map_async
      @logger.debug("starting async map in #{@name} with id #{Thread.current.object_id}")
      @logger.debug("queue: #{@queue}")
      Thimble.async do
        map &Proc.new
      end
      @logger.debug("finished async map in #{@name} with id #{Thread.current.object_id}")
      @result
    end

    # Will perform anything handed to this asynchronously. 
    # Requires a block
    # @return [Thread]
    def self.async
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
      @manager.current_workers(@id).each do |pid, pair|
        get_result(pair.worker)
      end
      while (@manager.worker_available? && batch = get_batch)
        @manager.sub_worker( @manager.get_worker(batch, &Proc.new), @id)
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
