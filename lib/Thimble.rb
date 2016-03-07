
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
  def initialize(array, manager = ThimbleManager.new)
    raise ArgumentError.new ("You need to pass a manager to Thimble!") unless manager.class == ThimbleManager
    raise ArgumentError.new ("There needs to be an iterable object passed to Thimble to start.") unless array.respond_to? :each
    @manager = manager
    @result = ThimbleQueue.new(array.size, "Result")
    @running = true
    super(array.size, "Main")
    push(array)
    close()
  end

  # Takes a block
  def parMap
    @running = true
    while @running
      manage_workers &Proc.new
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
    while batch.size < @manager.batch_size
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

  def manage_workers
    while (@manager.workerAvailable? && batch = getBatch)
      @manager.sub_worker( @manager.get_worker(batch, &Proc.new) )
    end
    @manager.current_workers.each do |tup|
      getResult(tup)
    end
    @running = false if !@manager.working? && !batch
  end

  def getResult(tuple)
    if @manager.worker_type == :fork
      if tuple.reader.ready?
        piped_result = tuple.reader.read
        @result.push(Marshal.load(piped_result))
        Process.kill("HUP", tuple.pid)
        @manager.rem_worker(tuple)
      end
    else
      if tuple.done == true
        @result.push(tuple.result)
        @manager.rem_worker(tuple)
      end
    end
  end

end

