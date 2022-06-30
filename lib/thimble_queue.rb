# frozen_string_literal: true

require 'logger'
require_relative 'queue_item'

module Thimble
  # noinspection RubyTooManyInstanceVariablesInspection
  class ThimbleQueue
    def initialize(size, name)
      unless size >= 1
        raise ArgumentError, "make sure there is a size for the queue greater than 1! size received #{size}"
      end

      @id = Digest::SHA256.digest(rand(10**100).to_s + Time.now.to_i.to_s)
      @name = name
      @size = size
      @mutex = Mutex.new
      @queue = []
      @closed = false
      @close_now = false
      @empty = ConditionVariable.new
      @full = ConditionVariable.new
      @logger = Logger.new($stdout)
      @logger.sev_threshold = Logger::UNKNOWN
    end

    include Enumerable
    attr_reader :size

    def set_logger(level)
      @logger.sev_threshold = level
    end

    def each
      while (item = self.next)
        yield item.item
      end
    end

    # Returns the size of the ThimbleQueue
    # @return [Integer]
    def length
      size
    end

    # Will concatenate an enumerable to the ThimbleQueue
    # @return [ThimbleQueue]
    # @param [Module<Enumerable>] other
    def +(other)
      raise ArgumentError, '+ requires another Enumerable!' unless other.class < Enumerable

      merged_thimble = ThimbleQueue.new(length + other.length, @name)
      each { |item| merged_thimble.push(item) }
      other.each { |item| merged_thimble.push(item) }
      merged_thimble
    end

    # Returns the first item in the queue
    # @return [Object]
    def next
      @mutex.synchronize do
        until @close_now
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
    # @param [Object] input_item
    def push(input_item)
      raise 'Queue is closed!' if @closed

      @logger.debug("Pushing into #{@name} values: #{input_item}")
      @mutex.synchronize do
        until offer(input_item)
          @full.wait(@mutex)
          @logger.debug("#{@name} is waiting on full")
        end
        @empty.broadcast
      end
      @logger.debug("Finished pushing int #{@name}: #{input_item}")
    end

    # This will flatten any nested arrays out and feed them one at
    # a time to the queue.
    # @return [nil]
    # @param [Object] input_item
    def push_flat(input_item)
      raise 'Queue is closed!' if @closed

      @logger.debug("Pushing flat into #{@name} values: #{input_item}")
      if input_item.respond_to? :each
        input_item.each { |item| push(item) }
      else
        @mutex.synchronize do
          until offer(input_item)
            @logger.debug("#{@name} is waiting on full")
            @full.wait(@mutex)
          end
          @empty.broadcast
        end
      end
      @logger.debug("Finished pushing flat into #{@name} values: #{input_item}")
    end

    # Closes the ThimbleQueue
    # @param [TrueClass, FalseClass]
    # @return [nil]
    def close(now = false)
      raise ArgumentError, 'now must be true or false' unless [true, false].include?(now)

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
      while (item = self.next)
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

    # @param [Object] x
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
