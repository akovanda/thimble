
require_relative 'Context.rb'
require_relative 'ThimbleQueue'
require_relative 'ThimbleBatch'
require 'io/wait'
require 'ostruct'
=begin
module Thimble
  attr_reader :work, :context
  # Work is the array of values to be worked on (anything)
  def Thimble.prep(context: Context.new)
    @context = context
  end

  def Thimble.map(work)
    @work = ThimbleQueue.new(work.length, work)
    @context = Context.new if @context.nil?
    raise "work is not iterable!" unless work.respond_to? :each
    work.map { |e| yield e }
  end
end
=end

class Thimble < ThimbleQueue
  attr_reader :batches, :currentPids
  def initialize(array, context = Context.new)
    raise "You need to pass a context to Thimble!" unless context.class == Context
    raise "There needs to be an iterable object passed to Thimble to start." unless array.respond_to? :each
    @context = context
    @batches = ThimbleQueue.new(@context.queueSize)
    @result = ThimbleQueue.new(array.size)
    @currentPids = []
    super(array.size)
    push(array)
    close()
    batchWork
  end

  # Takes a block
  def process
    while !@batches.closed?
      while (@currentPids.size.to_i<@context.pids)
        batch = @batches.take.item.item
        @currentPids = newPid(batch, &Proc.new)
      end
      p @currentPids
      @currentPids.each do |tup|
        while tup.reader.ready?
          @result.push(Marshal.load(tup.reader.gets))
        end
        
      end
    end
    @result
  end


  # Returns you a tuple of pid, and reader
  # requires a block 
  def newPid(batch)
    rd, wr = IO.pipe
    tup = OpenStruct.new
    pid = fork do
      rd.close 
      batch.each do |item|
        wr.puts Marshal.dump(yield (item.item))
      end
      wr.close
    end
    wr.close
    tup.pid = pid
    tup.reader = rd
    tup
  end

  # We will prep as many batches as the context allows
  def batchWork
    puts "batching"
    while batch = getBatch
      p batch
      if batch.item.size < @context.batchSize
        if batch.item.size > 0
          @batches.push(batch)
        end
      else
        @batches.push(batch)
      end
    end
    @batches.close()
    puts "done batching"
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
    while batch.size < @context.batchSize
      item = take
      p item
      if item.nil?
        return batch
      else
        batch << item
      end
    end
    ThimbleBatch.new(batch)
  end

end

t = Thimble.new((1..20).to_a)
res = t.process {|i| i + 1}

p res



