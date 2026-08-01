# frozen_string_literal: true

require 'logger'
require 'securerandom'
require_relative 'queue_item'
require_relative 'supervision'

module Thimble
  class ClosedQueueError < RuntimeError; end

  class ThimbleQueue
    include Enumerable

    attr_reader :capacity, :execution

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
      @execution = nil
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

    def attach_execution(execution)
      unless execution.is_a?(Execution)
        raise ArgumentError, 'execution must be a Thimble::Execution'
      end

      @mutex.synchronize do
        if @execution && !@execution.equal?(execution)
          raise RuntimeError, 'queue is already attached to another execution'
        end
        @execution = execution
      end
      self
    end

    def cancel(reason = nil)
      raise RuntimeError, 'queue is not attached to an execution' unless @execution

      @execution.cancel(reason)
    end

    def wait(timeout: nil)
      raise RuntimeError, 'queue is not attached to an execution' unless @execution

      @execution.wait(timeout: timeout)
    end

    def state
      @execution&.state
    end

    def error
      execution_error = @execution&.error
      return execution_error if execution_error

      @mutex.synchronize { @error }
    end

    def finished?
      @execution&.finished? || false
    end

    def running?
      @execution&.running? || false
    end

    def succeeded?
      @execution&.succeeded? || false
    end

    def failed?
      @execution&.failed? || false
    end

    def cancelled?
      @execution&.cancelled? || false
    end
    alias canceled? cancelled?

    def timed_out?
      @execution&.timed_out? || false
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

    def next(control: nil)
      loop do
        control&.checkpoint!
        wait_timeout = control&.remaining_time

        action, item = @mutex.synchronize do
          raise @error if @error

          unless @queue.empty?
            value = @queue.shift
            @logger.debug("#{@name}'s queue shifted to: #{value}")
            @full.signal
            next [:item, value]
          end

          next [:closed, nil] if @closed

          @empty.wait(@mutex, wait_timeout)
          [:retry, nil]
        end

        return item if action == :item
        return nil if action == :closed
      end
    end

    def push(input_item, control: nil)
      @logger.debug("Pushing into #{@name} values: #{input_item}")

      loop do
        control&.checkpoint!
        wait_timeout = control&.remaining_time

        action = @mutex.synchronize do
          raise @error if @error
          raise ClosedQueueError, "#{@name} is closed" if @closed

          if @queue.size < @capacity
            @queue << QueueItem.new(input_item)
            @empty.signal
            next :pushed
          end

          @logger.debug("#{@name} is waiting on full")
          @full.wait(@mutex, wait_timeout)
          :retry
        end
        break if action == :pushed
      end

      @logger.debug("Finished pushing into #{@name}: #{input_item}")
      self
    end

    # Flattens the outer enumerable by one level and pushes each value.
    def push_flat(input_item, control: nil)
      if input_item.respond_to?(:each)
        input_item.each { |item| push(item, control: control) }
      else
        push(input_item, control: control)
      end
      self
    end

    def close(now = false)
      raise ArgumentError, 'now must be true or false' unless [true, false].include?(now)

      @logger.debug("#{@name} is closing")
      @mutex.synchronize do
        next if @closed

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
    # future consumers/producers. The first terminal state wins.
    def abort(error)
      raise ArgumentError, 'error must be an Exception' unless error.is_a?(Exception)

      @mutex.synchronize do
        next if @closed

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
