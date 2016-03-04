
require_relative 'ThimbleManager'
require_relative 'ThimbleQueue'
require_relative 'QueueItem'
require 'io/wait'
require 'ostruct'
=begin
module Thimble
  attr_reader :work, :manager
  # Work is the array of values to be worked on (anything)
  def Thimble.prep(manager: manager.new)
    @manager = manager
  end

  def Thimble.map(work)
    @work = ThimbleQueue.new(work.length, work)
    @manager = manager.new if @manager.nil?
    raise "work is not iterable!" unless work.respond_to? :each
    work.map { |e| yield e }
  end
end
=end

class Thimble < ThimbleQueue
  attr_reader :currentPids
  def initialize(array, manager = ThimbleManager.new)
    raise "You need to pass a manager to Thimble!" unless manager.class == ThimbleManager
    raise "There needs to be an iterable object passed to Thimble to start." unless array.respond_to? :each
    @manager = manager
    @result = ThimbleQueue.new(array.size, "Result")
    @currentPids = []
    super(array.size, "Main")
    push(array)
    close()
  end

  # Takes a block
  def parMap
    running = true
    while running
      while (@currentPids.size<@manager.maxWorkers && batch = getBatch)
        @currentPids << @manager.getWorker(batch, &Proc.new)
      end
      @currentPids.each do |tup|
        getResult(tup)
      end
      running = false if @currentPids.size == 0 && !batch
    end
    @result.close()
    @result
  end

  # Will perform anything handed to this asynchronously. 
  # Requires a block
  def aSync
    Thread.new do |e|
      yield e
    end
  end

  private
  def getBatch
    batch = []
    while batch.size < @manager.batchSize
      item = take
      if item.nil?
        return nil if batch.size == 0
        return QueueItem.new(batch, "Batch")
      else
        batch << item
      end
    end
    QueueItem.new(batch, "Batch")
  end

  def getResult(tuple)
    if @manager.workerType == :fork
      if tuple.reader.ready?
        pipedResult = tuple.reader.read
        @result.push(Marshal.load(pipedResult))
        Process.kill("HUP", tuple.pid)
        @currentPids.delete(tuple) 
      end
    else
      if tuple.done == true
        @result.push(tuple.result)
        @currentPids.delete(tuple)  
      end
    end
  end

end

