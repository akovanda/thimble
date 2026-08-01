# frozen_string_literal: true

require 'thimble'

RSpec.describe 'Thimble supervision' do
  describe Thimble::CancellationToken do
    it 'cancels once, wakes waiters, and raises at checkpoints' do
      token = described_class.new
      observed = Queue.new
      waiter = Thread.new { observed << token.wait(timeout: 1) }

      expect(token.cancel('operator stop')).to be(true)
      expect(token.cancel('second stop')).to be(false)

      error = Timeout.timeout(1) { observed.pop }
      expect(error).to be_a(Thimble::CancelledError)
      expect(error.message).to include('operator stop')
      expect { token.checkpoint! }.to raise_error(Thimble::CancelledError, /operator stop/)
      waiter.join
    end

    it 'supports cancellation callbacks that can be unsubscribed' do
      token = described_class.new
      observed = []
      subscription = token.on_cancel { |error| observed << error }

      expect(subscription.unsubscribe).to be(true)
      token.cancel

      expect(observed).to be_empty
    end
  end

  describe Thimble::Execution do
    it 'records successful lifecycle state and timing' do
      execution = described_class.new(name: 'test stage')

      expect(execution.state).to eq(:pending)
      execution.start!
      expect(execution).to be_running
      execution.succeed!

      expect(execution.wait(timeout: 0)).to equal(execution)
      expect(execution).to be_succeeded
      expect(execution.started_at).to be_a(Time)
      expect(execution.finished_at).to be_a(Time)
      expect(execution.duration).to be >= 0
    end

    it 'returns nil when a lifecycle wait reaches its own observation timeout' do
      execution = described_class.new(name: 'waiting').start!

      expect(execution.wait(timeout: 0.01)).to be_nil
      execution.cancel
      execution.fail!(execution.token.error)
    end
  end

  describe 'supervised transformations' do
    it 'exposes execution state and cancellation through an async result queue' do
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)
      entered = Queue.new
      result = Thimble::Thimble.new([1], manager).map_async do |value|
        entered << true
        Queue.new.pop
        value
      end
      Timeout.timeout(1) { entered.pop }

      expect(result).to be_running
      expect(result.cancel('manual shutdown')).to be(true)
      expect { result.to_a }.to raise_error(Thimble::CancelledError, /manual shutdown/)
      expect(result.wait(timeout: 1)).to equal(result.execution)
      expect(result).to be_cancelled
      expect(manager).not_to be_working
    end

    it 'cancels connected stages through a shared token' do
      token = Thimble::CancellationToken.new
      entered = Queue.new
      first_manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)
      second_manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)

      first = Thimble::Thimble.new([1], first_manager)
      intermediate = first.map_async(cancellation: token) do |value|
        entered << true
        Queue.new.pop
        value
      end
      second = Thimble::Thimble.new(intermediate, second_manager)
      output = second.map_async(cancellation: token) { |value| value }
      Timeout.timeout(1) { entered.pop }

      token.cancel('pipeline stop')

      expect { output.to_a }.to raise_error(Thimble::CancelledError, /pipeline stop/)
      expect(first.execution.wait(timeout: 1)).to equal(first.execution)
      expect(second.execution.wait(timeout: 1)).to equal(second.execution)
      expect(first.execution).to be_cancelled
      expect(second.execution).to be_cancelled
      expect(first_manager).not_to be_working
      expect(second_manager).not_to be_working
    end

    it 'enforces a stage timeout while a worker is blocked' do
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)
      result = Thimble::Thimble.new([1], manager).map_async(timeout: 0.05) do |value|
        Queue.new.pop
        value
      end

      expect { result.to_a }.to raise_error(Thimble::StageTimeoutError, /0.05-second timeout/)
      expect(result.wait(timeout: 1)).to equal(result.execution)
      expect(result).to be_timed_out
      expect(manager).not_to be_working
    end

    it 'enforces a per-worker timeout independently of the stage deadline' do
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)
      result = Thimble::Thimble.new([1], manager).map_async(worker_timeout: 0.05) do |value|
        Queue.new.pop
        value
      end

      expect do
        result.to_a
      end.to raise_error(Thimble::WorkerTimeoutError, /processing 1 item/)
      expect(result.wait(timeout: 1)).to equal(result.execution)
      expect(result).to be_timed_out
      expect(result.error).to be_a(Thimble::WorkerTimeoutError)
      expect(manager).not_to be_working
    end

    it 'times out while downstream backpressure blocks result delivery' do
      manager = Thimble::Manager.new(max_workers: 2, batch_size: 1, queue_size: 1, worker_type: :thread)
      result = Thimble::Thimble.new((1..20).to_a, manager).map_async(timeout: 0.05) { |value| value }

      expect(result.wait(timeout: 1)).to equal(result.execution)
      expect(result).to be_timed_out
      expect { result.to_a }.to raise_error(Thimble::StageTimeoutError)
      expect(manager).not_to be_working
    end

    it 'interrupts and reaps a timed-out fork worker' do
      skip 'fork is not available on this platform' unless Process.respond_to?(:fork)

      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :fork)
      result = Thimble::Thimble.new([1], manager).map_async(worker_timeout: 0.05) do |value|
        Signal.trap('TERM', 'IGNORE')
        sleep 10
        value
      end

      expect { result.to_a }.to raise_error(Thimble::WorkerTimeoutError)
      expect(result.wait(timeout: 2)).to equal(result.execution)
      expect(manager).not_to be_working
      expect { Process.waitpid(-1, Process::WNOHANG) }.to raise_error(Errno::ECHILD)
    end

    it 'validates supervision options before starting work' do
      manager = Thimble::Manager.new(worker_type: :thread)

      expect do
        Thimble::Thimble.new([1], manager).map_async(timeout: 0) { |value| value }
      end.to raise_error(ArgumentError, /timeout/)
      expect do
        Thimble::Thimble.new([1], manager).map_async(worker_timeout: -1) { |value| value }
      end.to raise_error(ArgumentError, /worker_timeout/)
      expect do
        Thimble::Thimble.new([1], manager).map_async(cancellation: Object.new) { |value| value }
      end.to raise_error(ArgumentError, /CancellationToken/)
    end
  end
end
