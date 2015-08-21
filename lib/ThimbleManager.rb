require_relative 'ThimbleQueue'
require_relative 'Context'
require_relative 'Thimble'
# Here we will managed the Processes doing the actual work.

class ThimbleManager < Thimble
  attr_reader :context, :resultQueue, :workQueue, :batches
  def initialize(context, array)
    @context = context
    @batches = {}
    super(array)
  end

  def process(workQueue)
    while !@closed
      batch = getBatch(workQueue)
      if batch.size < @context.batchSize
        close(false)
        if batch.size > 0
          @batches[batch] = batch
        end
      else
        @batches[batch] = batch
      end
    end
  end

  def getBatch(workQueue)
    batch = []
    while batch.size < @context.batchSize
      item = workQueue.next
      puts item
      if item.nil?
        puts batch
        return batch
      else
        batch << item
      end
    end
    batch
  end
end

m = ThimbleManager.new(Context.small)
q = ThimbleQueue.new(5)
Thread.new {q.push (1..20).to_a}
sleep 1
m.process(q)

