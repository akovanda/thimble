require 'thread'
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
    end

    def each
      while item = self.next
        yield item.item
      end
    end

    def length
      size
    end

    def +(other)
      raise ArgumentError.new("+ requires another Enumerable!") unless other.class < Enumerable
      merged_thimble = ThimbleQueue.new(length + other.length, @name)
      self.each {|item| merged_thimble.push(item)}
      other.each {|item| merged_thimble.push(item)}
      merged_thimble
    end

    def next
      @mutex.synchronize  do
        while !@close_now
          a = @queue.shift
          if !a.nil?
            @full.broadcast
            return a
          else 
            return nil if @closed
            @empty.wait(@mutex)
          end
        end
      end
    end

    # This will push whatever it is handed to the queue
    def push(x)
      raise RuntimeError.new("Queue is closed!") if @closed
      @mutex.synchronize do
        while !offer(x)
          @full.wait(@mutex)
        end
        @empty.broadcast
      end
    end

    # This will flatten any nested arrays out and feed them one at
    # a time to the queue.
    def push_flat(x)
      raise RuntimeError.new("Queue is closed!") if @closed
      if x.respond_to? :each
        x.each {|item| push(item)}
      else
        @mutex.synchronize do
          while !offer(x)
            @full.wait(@mutex)
          end
          @empty.broadcast
        end
      end
    end

    def close(now = false)
      @mutex.synchronize do
        @closed = true
        @close_now = true if now
        @full.broadcast
        @empty.broadcast
      end
    end

    def to_a
      a = []
      while item = self.next
        a << item.item
      end
      a
    end

    def closed?
      @close
    end

    private
    def offer(x)
      if @queue.size < @size
        @queue << QueueItem.new(x)
        true
      else
        false
      end
    end
  end
end