# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble, 'Thimble' do
  result = [1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 9000, 10_000, 11_000, 12_000, 13_000, 14_000, 15_000,
            16_000, 17_000, 18_000, 19_000, 20_000, 21_000, 22_000, 23_000, 24_000, 25_000, 26_000, 27_000, 28_000,
            29_000, 30_000, 31_000, 32_000, 33_000, 34_000, 35_000, 36_000, 37_000, 38_000, 39_000, 40_000, 41_000,
            42_000, 43_000, 44_000, 45_000, 46_000, 47_000, 48_000, 49_000, 50_000, 51_000, 52_000, 53_000, 54_000,
            55_000, 56_000, 57_000, 58_000, 59_000, 60_000, 61_000, 62_000, 63_000, 64_000, 65_000, 66_000, 67_000,
            68_000, 69_000, 70_000, 71_000, 72_000, 73_000, 74_000, 75_000, 76_000, 77_000, 78_000, 79_000, 80_000,
            81_000, 82_000, 83_000, 84_000, 85_000, 86_000, 87_000, 88_000, 89_000, 90_000, 91_000, 92_000, 93_000,
            94_000, 95_000, 96_000, 97_000, 98_000, 99_000, 100_000].sort
  context 'map' do
    it 'returns results correctly with fork' do
      c = Thimble::Manager.new(max_workers: 20, batch_size: 20, queue_size: 10)
      t = Thimble::Thimble.new((1..100).to_a, c)
      res = t.map do |i|
        i * 1000
      end
      expect(res.to_a.sort).to eq result
    end

    it 'returns results correcly with thread' do
      c = Thimble::Manager.new(max_workers: 20, batch_size: 20, queue_size: 10, worker_type: :thread)
      t = Thimble::Thimble.new((1..100).to_a, c)
      res = t.map do |i|
        i * 1000
      end
      expect(res.to_a.sort).to eq result
    end

    it 'should get the proper results when two jobs happen at one time shaing a context' do
      c = Thimble::Manager.new(max_workers: 20, batch_size: 5, queue_size: 10, worker_type: :thread)
      t1 = Thimble::Thimble.new((1..100).to_a, c)
      t2 = Thimble::Thimble.new((1..100).to_a, c)
      res1 = nil
      res2 = nil
      thread1 = Thimble::Thimble.async do
        res1 = t1.map do |i|
          i * 1000
        end.to_a
      end
      thread2 = Thimble::Thimble.async do
        res2 = t2.map do |i|
          i * 1000
        end.to_a
      end
      thread1.join
      thread2.join
      expect(res1.sort).to eq result
      expect(res2.sort).to eq result
    end

    it 'should preserve arrays of arrays' do
      c = Thimble::Manager.new(max_workers: 5, batch_size: 1, queue_size: 10, worker_type: :fork)
      inner_array = [1, 2, 3, 4, 5]
      array = [inner_array.dup, inner_array.dup, inner_array.dup]
      t = Thimble::Thimble.new(array, c)
      res = t.map do |i|
        i.map { |e| e * 1000 }
      end
      res_inner = inner_array.map { |e| e * 1000 }
      expect(res.to_a.sort).to eq [res_inner, res_inner, res_inner]
    end

    it 'handle the exception and raise it to the user' do
      c = Thimble::Manager.new(max_workers: 5, batch_size: 5, queue_size: 10, worker_type: :fork)
      t1 = Thimble::Thimble.new((1..100).to_a, c)

      expect { t1.map(&:count).to_a.reduce(:+) }.to raise_exception(NoMethodError)
    end

    it 'handle the exception and raise it to the user for threads' do
      c = Thimble::Manager.new(max_workers: 1, batch_size: 5, queue_size: 10, worker_type: :thread)
      t1 = Thimble::Thimble.new((1..100).to_a, c)

      expect { t1.map(&:count).to_a.reduce(:+) }.to raise_exception(NoMethodError)
    end

    it 'should convert to array properly' do
      c = Thimble::Manager.new(max_workers: 5, batch_size: 5, queue_size: 10, worker_type: :fork)
      t1 = Thimble::Thimble.new((1..100).to_a, c)
      res = t1.map { |r| r }.reduce(:+)
      expect(res).to eq 5050
    end

    it 'should perform map asynchronously with thread' do
      c = Thimble::Manager.new(max_workers: 5, batch_size: 5, queue_size: 10, worker_type: :thread)
      rq = Thimble::ThimbleQueue.new(10, 'result queue')
      t1 = Thimble::Thimble.new((1..100).to_a, c, rq)
      res = t1.map_async { |r| r }
      expect(res.closed?).to eq false
      ta = res.to_a
      expect(ta.sort).to eq((1..100).to_a)
      expect(res.closed?).to eq true
    end

    it 'should perform map asynchronously with fork' do
      c1 = Thimble::Manager.new(max_workers: 5, batch_size: 5, queue_size: 10, worker_type: :fork)
      rq = Thimble::ThimbleQueue.new(10, 'result queue')
      t1 = Thimble::Thimble.new((1..100).to_a, c1, rq)
      res = t1.map_async { |r| r }
      expect(res.closed?).to eq false
      ta = res.to_a
      expect(ta.sort).to eq((1..100).to_a)
      expect(res.closed?).to eq true
    end
  end

  context 'initialization' do
    it 'should raise an error if manager is not a Manager instance' do
      expect { Thimble::Thimble.new([1, 2, 3], "not a manager") }.to raise_exception(ArgumentError, /You need to pass a manager to Thimble!/)
    end

    it 'should work with default manager when none is provided' do
      t = Thimble::Thimble.new([1, 2, 3])
      expect(t).to be_a(Thimble::Thimble)
      res = t.map { |x| x * 2 }
      expect(res.to_a.sort).to eq([2, 4, 6])
    end

    it 'should raise an error if array is not iterable' do
      manager = Thimble::Manager.new
      expect { Thimble::Thimble.new(42, manager) }.to raise_exception(ArgumentError, /There needs to be an iterable object passed to Thimble to start./)
    end

    it 'should raise an error if result is not a ThimbleQueue' do
      manager = Thimble::Manager.new
      expect { Thimble::Thimble.new([1, 2, 3], manager, []) }.to raise_exception(ArgumentError, /result needs to be an open ThimbleQueue/)
    end

    it 'should raise an error if result ThimbleQueue is already closed' do
      manager = Thimble::Manager.new
      result_queue = Thimble::ThimbleQueue.new(10, 'test')
      result_queue.close
      expect { Thimble::Thimble.new([1, 2, 3], manager, result_queue) }.to raise_exception(ArgumentError, /result needs to be an open ThimbleQueue/)
    end

    it 'should raise an error with an empty array' do
      manager = Thimble::Manager.new
      # Empty arrays create a queue with size 0, which is invalid
      expect { Thimble::Thimble.new([], manager) }.to raise_exception(ArgumentError, /make sure there is a size for the queue greater than 1/)
    end

    it 'should work with a single element array' do
      manager = Thimble::Manager.new(worker_type: :thread)
      t = Thimble::Thimble.new([42], manager)
      res = t.map { |x| x * 2 }
      expect(res.to_a).to eq([84])
    end
  end

  context 'edge cases' do
    it 'should handle strings in array' do
      manager = Thimble::Manager.new(worker_type: :thread, max_workers: 2, batch_size: 2)
      t = Thimble::Thimble.new(['hello', 'world', 'foo', 'bar'], manager)
      res = t.map { |x| x.upcase }
      expect(res.to_a.sort).to eq(['BAR', 'FOO', 'HELLO', 'WORLD'])
    end

    it 'should handle mixed types in array' do
      manager = Thimble::Manager.new(worker_type: :thread, max_workers: 2, batch_size: 2)
      t = Thimble::Thimble.new([1, 'two', 3.0, nil], manager)
      res = t.map { |x| x.to_s }
      expect(res.to_a.sort).to eq(['', '1', '3.0', 'two'])
    end

    it 'should handle large batch sizes correctly' do
      manager = Thimble::Manager.new(worker_type: :thread, max_workers: 1, batch_size: 1000)
      t = Thimble::Thimble.new((1..100).to_a, manager)
      res = t.map { |x| x * 2 }
      expect(res.to_a.sort).to eq((1..100).to_a.map { |x| x * 2 })
    end

    it 'should handle batch size of 1 correctly' do
      manager = Thimble::Manager.new(worker_type: :thread, max_workers: 2, batch_size: 1)
      t = Thimble::Thimble.new((1..10).to_a, manager)
      res = t.map { |x| x * 3 }
      expect(res.to_a.sort).to eq((1..10).to_a.map { |x| x * 3 })
    end

    it 'should work with ranges' do
      manager = Thimble::Manager.new(worker_type: :thread, max_workers: 3, batch_size: 5)
      t = Thimble::Thimble.new((1..20).to_a, manager)
      res = t.map { |x| x ** 2 }
      expect(res.to_a.sort).to eq((1..20).to_a.map { |x| x ** 2 })
    end
  end

  context 'async method' do
    it 'should return a Thread object' do
      thread = Thimble::Thimble.async { sleep 0.1 }
      expect(thread).to be_a(Thread)
      thread.join
    end

    it 'should execute block asynchronously' do
      start_time = Time.now
      thread = Thimble::Thimble.async { sleep 0.2 }
      elapsed = Time.now - start_time
      expect(elapsed).to be < 0.1
      thread.join
    end

    it 'should return value from block' do
      thread = Thimble::Thimble.async { 42 }
      expect(thread.value).to eq(42)
    end
  end
end
