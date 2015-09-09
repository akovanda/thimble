require 'thread'
require_relative 'QueueItem'

class ThimbleQueue
  attr_reader :size
  def initialize(size)
    raise ArgumentError.new("make sure there is a size for the queue greater than 1! size received #{size}") unless size >= 1
    @size = size
    @mutex = Mutex.new
    @queue = []
    @closed = false
    @closeNow = false
    @empty = ConditionVariable.new
    @full = ConditionVariable.new
  end
 
  def take
    @mutex.synchronize  do
      while !@closeNow
        a = @queue.shift
        p a
        if !a.nil?
          @full.broadcast
          puts "not nil #{a}"
          return a
        else 
          puts "in nil"
          return nil if @closed
          @empty.wait(@mutex)
        end
      end
    end
  end

  def push(x)
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
      puts "Closing Queue!"
      @close = true
      @closeNow = true if now
      @full.broadcast
      @empty.broadcast
    end
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


