# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble::Manager do
  describe 'configuration' do
    it 'creates a manager with defaults' do
      manager = described_class.new

      expect(manager.max_workers).to eq(6)
      expect(manager.batch_size).to eq(1000)
      expect(manager.queue_size).to eq(1000)
      expect(manager.worker_type).to eq(:fork)
    end

    it 'validates worker and queue limits as positive integers' do
      expect { described_class.new(max_workers: 0) }.to raise_error(ArgumentError, /max_workers/)
      expect { described_class.new(batch_size: -1) }.to raise_error(ArgumentError, /batch_size/)
      expect { described_class.new(queue_size: 0) }.to raise_error(ArgumentError, /queue_size/)
      expect { described_class.new(queue_size: 1.5) }.to raise_error(ArgumentError, /queue_size/)
    end

    it 'rejects unknown worker types' do
      expect { described_class.new(worker_type: :unknown) }.to raise_error(ArgumentError, /worker type/)
    end

    it 'does not change the process-wide thread exception policy' do
      original = Thread.abort_on_exception
      Thread.abort_on_exception = false

      described_class.new(worker_type: :thread)

      expect(Thread.abort_on_exception).to be(false)
    ensure
      Thread.abort_on_exception = original
    end
  end

  describe 'worker accounting' do
    it 'atomically enforces a shared worker limit across pipelines' do
      manager = described_class.new(max_workers: 2, batch_size: 1, queue_size: 2, worker_type: :thread)
      start = Queue.new
      entered = Queue.new
      release = Queue.new
      active_mutex = Mutex.new
      active = 0
      maximum = 0

      work = proc do |value|
        active_mutex.synchronize do
          active += 1
          maximum = [maximum, active].max
        end
        entered << true
        release.pop
        value
      ensure
        active_mutex.synchronize { active -= 1 }
      end

      thimbles = [
        Thimble::Thimble.new([1, 2], manager),
        Thimble::Thimble.new([3, 4], manager)
      ]
      results = []
      threads = thimbles.map do |thimble|
        Thread.new do
          start.pop
          values = thimble.map(&work).to_a
          active_mutex.synchronize { results.concat(values) }
        end
      end

      2.times { start << true }
      2.times { Timeout.timeout(1) { entered.pop } }
      expect(maximum).to eq(2)
      expect(manager.worker_available?).to be(false)

      4.times { release << true }
      threads.each { |thread| Timeout.timeout(2) { thread.join } }

      expect(results.sort).to eq([1, 2, 3, 4])
      expect(manager).not_to be_working
    end

    it 'tracks workers independently for each pipeline id' do
      manager = described_class.new(max_workers: 2, batch_size: 1, queue_size: 1, worker_type: :thread)
      batch = Thimble::QueueItem.new([Thimble::QueueItem.new(1)])
      release = Queue.new

      worker1 = manager.start_worker(batch, :first) { |value| release.pop; value }
      worker2 = manager.start_worker(batch, :second) { |value| release.pop; value }

      expect(manager.current_workers(:first).values.map(&:worker)).to contain_exactly(worker1)
      expect(manager.current_workers(:second).values.map(&:worker)).to contain_exactly(worker2)

      2.times { release << true }
      [worker1, worker2].each { |worker| worker.pid.join }
      manager.rem_worker(worker1)
      manager.rem_worker(worker2)
    end
  end

  describe 'presets' do
    it 'provides deterministic and small configurations' do
      deterministic = described_class.deterministic
      small = described_class.small

      expect([deterministic.max_workers, deterministic.batch_size, deterministic.queue_size]).to eq([1, 1, 1])
      expect([small.max_workers, small.batch_size, small.queue_size]).to eq([1, 3, 3])
    end
  end
end
