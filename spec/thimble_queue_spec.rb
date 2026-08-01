# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble::ThimbleQueue do
  describe 'bounded producer and consumer behavior' do
    it 'blocks a producer at capacity and wakes it when an item is consumed' do
      queue = described_class.new(1, 'bounded')
      queue.push(:first)
      started = Queue.new
      finished = Queue.new

      producer = Thread.new do
        started << true
        queue.push(:second)
        finished << true
      end

      Timeout.timeout(1) { started.pop }
      Timeout.timeout(1) { Thread.pass until producer.status == 'sleep' }
      expect(queue.current_size).to eq(1)
      expect(finished).to be_empty

      expect(queue.next.item).to eq(:first)
      Timeout.timeout(1) { finished.pop }
      queue.close

      expect(queue.to_a).to eq([:second])
      producer.join
    end

    it 'delivers accepted items exactly once with multiple producers and consumers' do
      queue = described_class.new(5, 'concurrent')
      consumed = Queue.new
      producers = 4.times.map do |producer_id|
        Thread.new do
          50.times { |index| queue.push([producer_id, index]) }
        end
      end
      consumers = 3.times.map do
        Thread.new do
          queue.each { |item| consumed << item }
        end
      end

      producers.each { |thread| Timeout.timeout(3) { thread.join } }
      queue.close
      consumers.each { |thread| Timeout.timeout(3) { thread.join } }

      values = 200.times.map { Timeout.timeout(1) { consumed.pop } }
      expect(values.uniq.length).to eq(200)
      expect(values.sort).to eq(4.times.flat_map { |producer_id| 50.times.map { |index| [producer_id, index] } }.sort)
    end
  end

  describe 'terminal states' do
    it 'rejects pushes after close' do
      queue = described_class.new(1, 'closed').close

      expect { queue.push(1) }.to raise_error(Thimble::ClosedQueueError, /closed/)
    end

    it 'wakes a producer blocked on a full queue when closed' do
      queue = described_class.new(1, 'blocked producer')
      queue.push(:first)
      outcome = Queue.new
      producer = Thread.new do
        queue.push(:second)
      rescue StandardError => error
        outcome << error
      end

      Timeout.timeout(1) { Thread.pass until producer.status == 'sleep' }
      queue.close

      expect(Timeout.timeout(1) { outcome.pop }).to be_a(Thimble::ClosedQueueError)
      producer.join
      expect(queue.to_a).to eq([:first])
    end

    it 'wakes a blocked consumer and ends iteration when closed' do
      queue = described_class.new(1, 'blocked consumer')
      outcome = Queue.new
      consumer = Thread.new { outcome << queue.next }

      Timeout.timeout(1) { Thread.pass until consumer.status == 'sleep' }
      queue.close

      expect(Timeout.timeout(1) { outcome.pop }).to be_nil
      consumer.join
    end

    it 'drains queued values after a graceful close' do
      queue = described_class.new(2, 'drain')
      queue.push_flat([1, 2])
      queue.close

      expect(queue.to_a).to eq([1, 2])
    end

    it 'discards queued values after an immediate close' do
      queue = described_class.new(2, 'immediate')
      queue.push_flat([1, 2])
      queue.close(true)

      expect(queue.to_a).to eq([])
    end

    it 'propagates abort errors to blocked consumers' do
      queue = described_class.new(1, 'abort')
      outcome = Queue.new
      consumer = Thread.new do
        queue.next
      rescue StandardError => error
        outcome << error
      end

      Timeout.timeout(1) { Thread.pass until consumer.status == 'sleep' }
      queue.abort(ArgumentError.new('source failed'))

      error = Timeout.timeout(1) { outcome.pop }
      expect(error).to be_a(ArgumentError)
      expect(error.message).to eq('source failed')
      consumer.join
    end

    it 'propagates abort errors to blocked producers' do
      queue = described_class.new(1, 'abort producer')
      queue.push(:first)
      outcome = Queue.new
      producer = Thread.new do
        queue.push(:second)
      rescue StandardError => error
        outcome << error
      end

      Timeout.timeout(1) { Thread.pass until producer.status == 'sleep' }
      queue.abort(RuntimeError.new('cancelled'))

      expect(Timeout.timeout(1) { outcome.pop }.message).to eq('cancelled')
      producer.join
    end
  end

  describe 'compatibility and introspection' do
    it 'reports capacity through size and length while exposing current depth separately' do
      queue = described_class.new(3, 'metrics')
      expect(queue.capacity).to eq(3)
      expect(queue.size).to eq(3)
      expect(queue.length).to eq(3)
      expect(queue.current_size).to eq(0)
      expect(queue).to be_empty

      queue.push(1)
      expect(queue.current_size).to eq(1)
      expect(queue).not_to be_empty
      expect(queue).not_to be_full
    end

    it 'returns an enumerator when each is called without a block' do
      queue = described_class.new(2, 'enumerator')
      queue.push_flat([1, 2]).close

      expect(queue.each).to be_a(Enumerator)
      expect(queue.each.to_a).to eq([1, 2])
    end

    it 'preserves nested arrays when pushing flat' do
      queue = described_class.new(3, 'nested')
      queue.push_flat([[1, 2], [3, 4], [5, 6]]).close

      expect(queue.to_a).to eq([[1, 2], [3, 4], [5, 6]])
    end

    it 'preserves destructive merge compatibility' do
      queue = described_class.new(2, 'left')
      queue.push_flat([1, 2]).close

      merged = queue + [3, 4]
      merged.close

      expect(merged.to_a).to eq([1, 2, 3, 4])
    end

    it 'validates queue capacity' do
      expect { described_class.new(0, 'invalid') }.to raise_error(ArgumentError, /integer greater than 0/)
      expect { described_class.new('1', 'invalid') }.to raise_error(ArgumentError, /integer greater than 0/)
    end
  end
end
