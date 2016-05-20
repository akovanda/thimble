require 'thread'
require 'logger'
require_relative 'QueueItem'

module Thimble
  class ThimbleQueue
    include Enumerable
    attr_reader :size
    def initialize(size, name)
      raise ArgumentError.new("make sure there is a size for the queue greater than 1! size received #{size}") unless size >= 1
      @id = Digest::SHA256.digest(rand(10**100).to_s + Time.now.to_i.to_s)
      @name = name
      @size = size
      @mutex = Mutex.new
      @queue = []
      @closed = false
      @close_now = false
      @empty = ConditionVariable.new
      @full = ConditionVariable.new
      @logger = Logger.new(STDOUT)
      @logger.sev_threshold = Logger::UNKNOWN
    end

    def setLogger(level)
      @logger.sev_threshold = level
    end

    def each
      while item = self.next
        yield item.item
      end
    end

    # Returns the size of the ThimbleQueue
    # @return [Fixnum]
    def length
      size
    end

    # Will concatenate an enumerable to the ThimbleQueue
    # @param [Enumerable]
    # @return [ThimbleQueue]
    def +(other)
      raise ArgumentError.new("+ requires another Enumerable!") unless other.class < Enumerable
      merged_thimble = ThimbleQueue.new(length + other.length, @name)
      self.each {|item| merged_thimble.push(item)}
      other.each {|item| merged_thimble.push(item)}
      merged_thimble
    end

    # Returns the first item in the queue
    # @return [Object]
    def next
      @mutex.synchronize  do
        while !@close_now
          a = @queue.shift
          @logger.debug("#{@name}'s queue shifted to: #{a}")
          if !a.nil?
            @full.broadcast
            @empty.broadcast
            return a
          else 
            @logger.debug("#{@name}'s queue is currently closed?: #{closed?}")
            return nil if closed?
            @empty.wait(@mutex)
          end
        end
      end
    end

    # This will push whatever it is handed to the queue
    # @param [Object]
    def push(x)
      raise RuntimeError.new("Queue is closed!") if @closed
      @logger.debug("Pushing into #{@name} values: #{x}")
      @mutex.synchronize do
        while !offer(x)
          @full.wait(@mutex)
          @logger.debug("#{@name} is waiting on full")
        end
        @empty.broadcast
      end
      @logger.debug("Finished pushing int #{@name}: #{x}")
    end

    # This will flatten any nested arrays out and feed them one at
    # a time to the queue.
    # @param [Object, Enumerable]
    # @return [nil]
    def push_flat(x)
      raise RuntimeError.new("Queue is closed!") if @closed
      @logger.debug("Pushing flat into #{@name} values: #{x}")
      if x.respond_to? :each
        x.each {|item| push(item)}
      else
        @mutex.synchronize do
          while !offer(x)
            @logger.debug("#{@name} is waiting on full")
            @full.wait(@mutex)
          end
          @empty.broadcast
        end
      end
      @logger.debug("Finished pushing flat into #{@name} values: #{x}")
    end

    # Closes the ThibleQueue
    # @param [TrueClass, FalseClass]
    # @return [nil]
    def close(now = false)
      raise ArgumentError.new("now must be true or false") unless (now == true || now == false)
      @logger.debug("#{@name} is closing")
      @mutex.synchronize do
        @closed = true
        @close_now = true if now
        @full.broadcast
        @empty.broadcast
      end
      @logger.debug("#{@name} is closed: #{@closed} now: #{@close_now}")
    end

    # Will force the ThimbleQueue into an array
    # @return [Array[Object]]
    def to_a
      a = []
      while item = self.next
        a << item.item
      end
      a
    end

    # checks if the ThimbleQueue is closed
    # @return [TrueClass, FalseClass]
    def closed?
      @closed
    end

    private
    def offer(x)
      if @queue.size < @size
        @queue << QueueItem.new(x)
        @empty.broadcast
        true
      else
        false
      end
    end
  end
end