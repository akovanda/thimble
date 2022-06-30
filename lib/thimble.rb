# frozen_string_literal: true

require_relative 'manager'
require_relative 'thimble_queue'
require_relative 'queue_item'
require 'io/wait'
require 'ostruct'

module Thimble
  class Thimble < ThimbleQueue
    def initialize(array, manager = Manager.new, result = nil, name = 'Main')
      raise ArgumentError, 'You need to pass a manager to Thimble!' unless manager.instance_of?(Manager)

      unless array.respond_to? :each
        raise ArgumentError,
              'There needs to be an iterable object passed to Thimble to start.'
      end

      @result = if result.nil?
                  ThimbleQueue.new(array.size, 'Result')
                else
                  result
                end
      unless @result.instance_of?(ThimbleQueue) && !@result.closed?
        raise ArgumentError,
              'result needs to be an open ThimbleQueue'
      end

      @manager = manager
      @running = true
      super(array.size, name)
      @logger.debug("loading thimble #{name}")
      array.each { |item| push(item) }
      @logger.debug("finished loading thimble #{name}")
      close
    end

    # This will use the manager and transform your thimble queue.
    # requires a block
    # @return [ThimbleQueue]
    def map(&block)
      @logger.debug("starting map in #{@name} with id #{Thread.current.object_id}")
      @running = true
      manage_workers(&block) while @running
      @result.close
      @logger.debug("finishing map in #{@name} with id #{Thread.current.object_id}")
      @result
    end

    # This will use the manager and transform the thimble queue asynchronously.
    # Will return the result instantly, so you can use it for next stage processing.
    # requires a block
    # @return [ThimbleQueue]
    # @param [Proc] block
    def map_async(&block)
      @logger.debug("starting async map in #{@name} with id #{Thread.current.object_id}")
      @logger.debug("queue: #{@queue}")
      Thimble.async do
        map(&block)
      end
      @logger.debug("finished async map in #{@name} with id #{Thread.current.object_id}")
      @result
    end

    # Will perform anything handed to this asynchronously.
    # Requires a block
    # @return [Thread]
    def self.async(&block)
      Thread.new(&block)
    end

    private

    def get_batch
      batch = []
      while batch.size < @manager.batch_size
        item = self.next
        if item.nil?
          return nil if batch.size.zero?

          return QueueItem.new(batch, 'Batch')
        else
          batch << item
        end
      end
      QueueItem.new(batch, 'Batch')
    end

    def manage_workers(&block)
      @manager.current_workers(@id).each do |_pid, pair|
        get_result(pair.worker)
      end
      while @manager.worker_available? && batch = get_batch
        @manager.sub_worker(@manager.get_worker(batch, &block), @id)
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
          Process.kill('HUP', tuple.pid)
          @manager.rem_worker(tuple)
        end
      elsif tuple.done == true
        push_result(tuple.result)
        @manager.rem_worker(tuple)
      end
    end

    def push_result(result)
      if result.respond_to? :each
        result.each { |r| @result.push(r) }
      else
        @result.push(result)
      end
    end
  end
end
