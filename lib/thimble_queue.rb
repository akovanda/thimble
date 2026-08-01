# frozen_string_literal: true

require 'logger'
require 'securerandom'
require_relative 'queue_item'

module Thimble
  class ClosedQueueError < RuntimeError; end

  class ThimbleQueue
    include Enumerable

    attr_reader :capacity

    def initialize(size, name, logger: nil)
      unless size.is_a?(Integer) && size.positive?
        raise ArgumentError, "queue size must be an integer greater than 0; received #{size.inspect}"
      end

      @id = SecureRandom.uuid
      @name = name
      @capacity = size
      @mutex = Mutex.new
      @queue = []
      @closed = false
      @close_now = false
      @error = nil
      @empty = ConditionVariable.new
      @full = ConditionVariable.new
      @logger = logger || Logger.new($stdout)
      @logger.level = Logger::UNKNOWN
    end

    # Compatibility: historically #size and #length reported capacity, not depth.
    alias size capacity

    def length
      capacity
    end

    def current_size
      @mutex.synchronize { @queue.size }
    end

    def empty?
      current_size.zero?
    end

    def full?
      current_size >= capacity
    end

    def set_logger(level)
      @logger.level = level
      self
    end

    def each
      return enum_for(:each) unless block_given?

      while (item = self.next)
        yield item.item
      end
    end

    # Will concatenate an enumerable to the ThimbleQueue.
    # Reading either queue is destructive, matching the historical behavior.
    def +(other)
      raise ArgumentError, '+ requires another Enumerable!' unless other.respond_to?(:each)

      values = to_a
      other.each { |item| values << item }
      merged_thimble = ThimbleQueue.new([values.length, 1].max, @name)
      merged_thimble.push_flat(values)
      merged_thimble
    end

    def next
      @mutex.synchronize do
        loop do
          raise @error if @error

          unless @queue.empty?
            item = @queue.shift
            @logger.debug("#{@name}'s queue shifted to: #{item}")
            @full.signal
            return item
          end

          return nil if @closed

          @empty.wait(@mutex)
        end
      end
    end

    def push(input_item)
      @logger.debug("Pushing into #{@name} values: #{input_item}")

      @mutex.synchronize do
        loop do
          raise @error if @error
          raise ClosedQueueError, "#{@name} is closed" if @closed

          if @queue.size < @capacity
            @queue << QueueItem.new(input_item)
            @empty.signal
            break
          end

          @logger.debug("#{@name} is waiting on full")
          @full.wait(@mutex)
        end
      end

      @logger.debug("Finished pushing into #{@name}: #{input_item}")
      self
    end

    # Flattens the outer enumerable by one level and pushes each value.
    def push_flat(input_item)
      if input_item.respond_to?(:each)
        input_item.each { |item| push(item) }
      else
        push(input_item)
      end
      self
    end

    def close(now = false)
      raise ArgumentError, 'now must be true or false' unless [true, false].include?(now)

      @logger.debug("#{@name} is closing")
      @mutex.synchronize do
        @closed = true
        if now
          @close_now = true
          @queue.clear
        end
        @full.broadcast
        @empty.broadcast
      end
      @logger.debug("#{@name} is closed: #{@closed} now: #{@close_now}")
      self
    end

    # Terminates the queue immediately and propagates +error+ to blocked and
    # future consumers/producers.
    def abort(error)
      raise ArgumentError, 'error must be an Exception' unless error.is_a?(Exception)

      @mutex.synchronize do
        @error = error
        @closed = true
        @close_now = true
        @queue.clear
        @full.broadcast
        @empty.broadcast
      end
      self
    end

    def to_a
      each.to_a
    end

    def closed?
      @mutex.synchronize { @closed }
    end

    def aborted?
      @mutex.synchronize { !@error.nil? }
    end
  end
end
