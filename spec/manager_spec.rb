# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble::Manager, 'Manager' do
  context 'initialization' do
    it 'creates a manager with default values' do
      manager = Thimble::Manager.new
      expect(manager.max_workers).to eq(6)
      expect(manager.batch_size).to eq(1000)
      expect(manager.queue_size).to eq(1000)
      expect(manager.worker_type).to eq(:fork)
    end

    it 'creates a manager with custom values' do
      manager = Thimble::Manager.new(max_workers: 10, batch_size: 50, queue_size: 100, worker_type: :thread)
      expect(manager.max_workers).to eq(10)
      expect(manager.batch_size).to eq(50)
      expect(manager.queue_size).to eq(100)
      expect(manager.worker_type).to eq(:thread)
    end

    it 'raises an error with invalid worker type' do
      expect { Thimble::Manager.new(worker_type: :invalid) }.to raise_exception(ArgumentError, /worker type must be either :fork or :thread/)
    end

    it 'raises an error with max_workers less than 1' do
      expect { Thimble::Manager.new(max_workers: 0) }.to raise_exception(ArgumentError, /max_workers must be greater than 0/)
      expect { Thimble::Manager.new(max_workers: -1) }.to raise_exception(ArgumentError, /max_workers must be greater than 0/)
    end

    it 'raises an error with batch_size less than 1' do
      expect { Thimble::Manager.new(batch_size: 0) }.to raise_exception(ArgumentError, /batch size must be greater than 0/)
      expect { Thimble::Manager.new(batch_size: -1) }.to raise_exception(ArgumentError, /batch size must be greater than 0/)
    end
  end

  context 'worker availability' do
    it 'reports worker available when no workers are running' do
      manager = Thimble::Manager.new(max_workers: 2)
      expect(manager.worker_available?).to eq(true)
    end

    it 'reports not working when no workers are running' do
      manager = Thimble::Manager.new(max_workers: 2)
      expect(manager.working?).to eq(false)
    end
  end

  context 'class methods' do
    it 'creates a deterministic manager' do
      manager = Thimble::Manager.deterministic
      expect(manager.max_workers).to eq(1)
      expect(manager.batch_size).to eq(1)
      expect(manager.queue_size).to eq(1)
    end

    it 'creates a small manager' do
      manager = Thimble::Manager.small
      expect(manager.max_workers).to eq(1)
      expect(manager.batch_size).to eq(3)
      expect(manager.queue_size).to eq(3)
    end
  end

  context 'worker management' do
    it 'tracks current workers for thread type' do
      manager = Thimble::Manager.new(max_workers: 5, worker_type: :thread)
      batch = Thimble::QueueItem.new([Thimble::QueueItem.new(1), Thimble::QueueItem.new(2)])
      
      worker = manager.get_worker(batch) { |x| x * 2 }
      manager.sub_worker(worker, :test_id)
      
      expect(manager.working?).to eq(true)
      expect(manager.worker_available?).to eq(true)
      
      worker.pid.join # Wait for thread to complete
      
      manager.rem_worker(worker)
      expect(manager.working?).to eq(false)
    end

    it 'tracks current workers for fork type' do
      manager = Thimble::Manager.new(max_workers: 5, worker_type: :fork)
      batch = Thimble::QueueItem.new([Thimble::QueueItem.new(1), Thimble::QueueItem.new(2)])
      
      worker = manager.get_worker(batch) { |x| x * 2 }
      manager.sub_worker(worker, :test_id)
      
      expect(manager.working?).to eq(true)
      expect(manager.worker_available?).to eq(true)
      
      # Let the child finish and the pipe deliver results
      sleep 0.1

      manager.rem_worker(worker)
      expect(manager.working?).to eq(false)
    end

    it 'correctly reports worker unavailable when at max capacity' do
      manager = Thimble::Manager.new(max_workers: 1, worker_type: :thread)
      batch = Thimble::QueueItem.new([Thimble::QueueItem.new(1)])
      
      worker = manager.get_worker(batch) { |x| sleep 0.5; x * 2 }
      manager.sub_worker(worker, :test_id)
      
      expect(manager.worker_available?).to eq(false)
      
      worker.pid.join
      manager.rem_worker(worker)
    end

    it 'filters current workers by id' do
      manager = Thimble::Manager.new(max_workers: 5, worker_type: :thread)
      batch1 = Thimble::QueueItem.new([Thimble::QueueItem.new(1)])
      batch2 = Thimble::QueueItem.new([Thimble::QueueItem.new(2)])
      
      worker1 = manager.get_worker(batch1) { |x| sleep 0.5; x * 2 }
      worker2 = manager.get_worker(batch2) { |x| sleep 0.5; x * 3 }
      
      manager.sub_worker(worker1, :id1)
      manager.sub_worker(worker2, :id2)
      
      id1_workers = manager.current_workers(:id1)
      expect(id1_workers.size).to eq(1)
      
      id2_workers = manager.current_workers(:id2)
      expect(id2_workers.size).to eq(1)
      
      worker1.pid.join
      worker2.pid.join
      manager.rem_worker(worker1)
      manager.rem_worker(worker2)
    end
  end
end
