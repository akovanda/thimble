# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble::Thimble do
  describe '#map' do
    it 'maps with thread workers while bounding the source queue' do
      manager = Thimble::Manager.new(max_workers: 3, batch_size: 2, queue_size: 2, worker_type: :thread)
      thimble = described_class.new((1..20).to_a, manager)

      expect(thimble.capacity).to eq(2)
      expect(thimble.map { |value| value * 2 }.to_a.sort).to eq((1..20).map { |value| value * 2 })
    end

    it 'maps with fork workers and reaps child processes' do
      skip 'fork is not available on this platform' unless Process.respond_to?(:fork)

      manager = Thimble::Manager.new(max_workers: 3, batch_size: 2, queue_size: 2, worker_type: :fork)
      result = described_class.new((1..12).to_a, manager).map { |value| value * 3 }.to_a

      expect(result.sort).to eq((1..12).map { |value| value * 3 })
      expect { Process.waitpid(-1, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    end

    it 'supports empty inputs' do
      manager = Thimble::Manager.new(worker_type: :thread, queue_size: 1)

      expect(described_class.new([], manager).map { |value| value }.to_a).to eq([])
    end

    it 'preserves array values returned by workers' do
      manager = Thimble::Manager.new(max_workers: 2, batch_size: 1, queue_size: 2, worker_type: :thread)
      result = described_class.new([1, 2], manager).map { |value| [value, value * 2] }.to_a

      expect(result).to contain_exactly([1, 2], [2, 4])
    end

    it 'does not consume the source before processing starts' do
      consumed = 0
      source = [1, 2, 3].lazy.map do |value|
        consumed += 1
        value
      end
      manager = Thimble::Manager.new(worker_type: :thread, queue_size: 1)
      thimble = described_class.new(source, manager)

      expect(consumed).to eq(0)
      expect(thimble.map { |value| value }.to_a).to eq([1, 2, 3])
      expect(consumed).to eq(3)
    end

    it 'propagates thread worker exceptions without changing global Thread settings' do
      original = Thread.abort_on_exception
      Thread.abort_on_exception = false
      manager = Thimble::Manager.new(max_workers: 2, batch_size: 1, queue_size: 2, worker_type: :thread)

      expect do
        described_class.new([1, 2], manager).map(&:missing_method)
      end.to raise_error(NoMethodError, /missing_method/)
      expect(Thread.abort_on_exception).to be(false)
    ensure
      Thread.abort_on_exception = original
    end

    it 'turns non-marshallable fork results into a clear worker error' do
      skip 'fork is not available on this platform' unless Process.respond_to?(:fork)

      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :fork)

      expect do
        described_class.new([1], manager).map { proc {} }.to_a
      end.to raise_error(RuntimeError, /could not be marshaled/)
    end

    it 'requires a finite source size for synchronous result buffering' do
      source = Enumerator.new { |yielder| yielder << 1 }
      manager = Thimble::Manager.new(worker_type: :thread)
      thimble = described_class.new(source, manager)

      expect { thimble.map { |value| value } }.to raise_error(ArgumentError, /map_async/)
    end

    it 'exposes manager batches to bulk operations' do
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 3, queue_size: 2, worker_type: :thread)
      result = described_class.new((1..10).to_a, manager).map_batches(&:sum).to_a

      expect(result).to eq([6, 15, 24, 10])
    end

    it 'can only be consumed once' do
      manager = Thimble::Manager.new(worker_type: :thread)
      thimble = described_class.new([1], manager)
      thimble.map { |value| value }.to_a

      expect { thimble.map { |value| value } }.to raise_error(RuntimeError, /already been consumed/)
    end
  end

  describe '#map_async' do
    it 'streams unknown-size sources through bounded input and result queues' do
      source = Enumerator.new do |yielder|
        10.times { |value| yielder << value }
      end
      manager = Thimble::Manager.new(max_workers: 2, batch_size: 1, queue_size: 2, worker_type: :thread)
      result = described_class.new(source, manager).map_async { |value| value + 1 }

      expect(result.capacity).to eq(2)
      expect(result.to_a.sort).to eq((1..10).to_a)
    end

    it 'streams batches asynchronously' do
      source = Enumerator.new { |yielder| 7.times { |value| yielder << value } }
      manager = Thimble::Manager.new(max_workers: 2, batch_size: 3, queue_size: 2, worker_type: :thread)
      result = described_class.new(source, manager).map_batches_async(&:sum)

      expect(result.to_a.sort).to eq([3, 6, 12])
    end

    it 'propagates asynchronous failures through the result queue' do
      manager = Thimble::Manager.new(max_workers: 2, batch_size: 1, queue_size: 2, worker_type: :thread)
      result = described_class.new([1, 2, 3], manager).map_async do |value|
        raise 'failed' if value == 2

        value
      end

      expect { result.to_a }.to raise_error(RuntimeError, 'failed')
      expect(result).to be_aborted
    end

    it 'propagates source enumeration failures through the result queue' do
      source = Enumerator.new do |yielder|
        yielder << 1
        raise 'source failed'
      end
      manager = Thimble::Manager.new(worker_type: :thread, queue_size: 1)
      result = described_class.new(source, manager).map_async { |value| value }

      expect { result.to_a }.to raise_error(RuntimeError, 'source failed')
    end
  end

  describe '.async' do
    it 'returns a thread carrying the block value' do
      thread = described_class.async { 42 }

      expect(thread).to be_a(Thread)
      expect(thread.value).to eq(42)
    end
  end
end
