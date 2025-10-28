# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble::ThimbleQueue, 'thimblequeue' do
  context 'thimblequeue' do
    it 'should not allow more data after being closed' do
      q1 = Thimble::ThimbleQueue.new(10, '1')
      q1.close
      expect { q1.push(1) }.to raise_exception(RuntimeError)
    end

    it 'should not accept more items than the given size' do
      ary = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      q1 = Thimble::ThimbleQueue.new(5, '1')
      Thimble::Thimble.async do
        ary.each { q1.push(ary.shift) }
      end
      sleep 1
      expect(ary.size).to eq(5)
    end

    it 'should merge queues' do
      ary = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      q1 = Thimble::ThimbleQueue.new(10, '1')
      q2 = Thimble::ThimbleQueue.new(10, '2')
      q1.push_flat(ary)
      q2.push_flat(ary)
      q1.close
      q2.close
      q3 = q1 + q2
      q3.close
      expect(q3.to_a.sort).to eq [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10]
    end

    it 'should merge an array and a queue' do
      ary = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
      q1 = Thimble::ThimbleQueue.new(10, '1')
      q1.push_flat(ary)
      q1.close
      q2 = q1 + ary
      q2.close
      expect(q2.to_a.sort).to eq [1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10]
    end

    it 'should not close if now is not true or false' do
      q = Thimble::ThimbleQueue.new(10, '1')
      expect { q.close('stuff') }.to raise_exception(ArgumentError)
    end

    it 'should handle to_a on an empty queue' do
      q = Thimble::ThimbleQueue.new(10, '1')
      q.close
      expect(q.to_a).to eq([])
    end

    it 'should handle to_a with single item' do
      q = Thimble::ThimbleQueue.new(10, '1')
      q.push(42)
      q.close
      expect(q.to_a).to eq([42])
    end

    it 'should properly handle push_flat with nested arrays' do
      q = Thimble::ThimbleQueue.new(20, '1')
      q.push_flat([[1, 2], [3, 4], [5, 6]])
      q.close
      expect(q.to_a.sort).to eq([[1, 2], [3, 4], [5, 6]])
    end

    it 'should properly handle push_flat with single value' do
      q = Thimble::ThimbleQueue.new(10, '1')
      q.push_flat(42)
      q.close
      expect(q.to_a).to eq([42])
    end

    it 'should close immediately when close(true) is called' do
      q = Thimble::ThimbleQueue.new(10, '1')
      q.push(1)
      q.push(2)
      q.close(true)
      expect(q.closed?).to eq(true)
      # Queue should be closed now
      result = q.next
      expect(result).to be_nil
    end

    it 'should allow closing with false explicitly' do
      q = Thimble::ThimbleQueue.new(10, '1')
      q.push(1)
      q.close(false)
      expect(q.closed?).to eq(true)
    end

    it 'should raise error when merging with non-enumerable' do
      q = Thimble::ThimbleQueue.new(10, '1')
      expect { q + 42 }.to raise_exception(ArgumentError, /\+ requires another Enumerable!/)
    end

    it 'should work with each iterator' do
      q = Thimble::ThimbleQueue.new(10, '1')
      q.push_flat([1, 2, 3, 4, 5])
      q.close
      results = []
      q.each { |x| results << x }
      expect(results).to eq([1, 2, 3, 4, 5])
    end

    it 'should return correct length' do
      q = Thimble::ThimbleQueue.new(42, '1')
      expect(q.length).to eq(42)
      expect(q.size).to eq(42)
    end

    it 'should handle complex objects' do
      q = Thimble::ThimbleQueue.new(10, '1')
      obj1 = { key: 'value', number: 42 }
      obj2 = { key: 'other', number: 100 }
      q.push(obj1)
      q.push(obj2)
      q.close
      results = q.to_a
      expect(results).to include(obj1)
      expect(results).to include(obj2)
    end
  end

  context 'initialization errors' do
    it 'should raise error with size less than 1' do
      expect { Thimble::ThimbleQueue.new(0, 'test') }.to raise_exception(ArgumentError, /make sure there is a size for the queue greater than 1/)
      expect { Thimble::ThimbleQueue.new(-5, 'test') }.to raise_exception(ArgumentError, /make sure there is a size for the queue greater than 1/)
    end
  end
end
