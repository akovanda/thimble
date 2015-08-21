require 'thread'
require_relative 'QueueItem'

class QueueWithTimeout
  attr_reader :size
  def initialize(size)
    raise ArgumentError.new("make sure there is a size for the queue greater than 1! size received #{size}") unless size >= 1
    @size = size
    @mutex = Mutex.new
    @queue = []
    @closed = false
    @closedImmediately = false
    @empty = ConditionVariable.new
    @full = ConditionVariable.new
  end
 
  def next
    @mutex.synchronize  do
      while !@closedImmediately
        a = @queue.shift
        unless a.nil?
          @full.broadcast
          return a
        else 
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

  private
  def offer(x)
    if @queue.size < @size
      @queue << QueueItem.new(x)
      @empty.broadcast
    else
    end
  end
end


a = QueueWithTimeout.new(1)
p a.size
b = Thread.new do 
  puts a.next
  puts a.next
end
a.push 2
b.join

#p a.pop

