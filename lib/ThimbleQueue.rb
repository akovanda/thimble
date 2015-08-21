require 'thread'
require_relative 'QueueItem'

class ThimbleQueue
  attr_reader :size
  def initialize(size, values = [])
    @queue = Queue.new
    @inprogress = {}
    push(values)
  end

  def push(values)
    if values.respond_to? :each
      values.each {|v| @queue << v}
    else 
      @queue << values
    end
  end

  def pop
    QueueItem.new(@queue.pop)
  end

end

t = ThimbleQueue.new(1000,[1,2,3,4,5,6])
p t.pop

class QueueWithTimeout
  def initialize
    @mutex = Mutex.new
    @queue = []
    @closed = false
    @recieved = ConditionVariable.new
    @empty = ConditionVariable.new
    @full = ConditionVariable.new
  end
 
  def next
    @mutex.synchronize  do
      a = @queue.shift
      unless a.nil?
        puts "broadcast"
        @full.broadcast
        a
      else 
        return nil if @closed
        @empty.wait(@mutex)
      end
    end
  end

  def <<(x)
    @mutex.synchronize do
      @queue << x
      @recieved.signal
      @empty.broadcast
    end
  end
 
  def pop(non_block = false)
    pop_with_timeout(non_block ? 0 : nil)
  end
 
  def pop_with_timeout(timeout = nil)
    @mutex.synchronize do
      if @queue.empty?
        @recieved.wait(@mutex, timeout) if timeout != 0
        #if we're still empty after the timeout, raise exception
        raise ThreadError, "queue empty" if @queue.empty?
      end
      @queue.shift
    end
  end
end


a = QueueWithTimeout.new
Thread.new do 
  a << 1
  puts a.next
  puts a.next
end
a << 2
#p a.pop

