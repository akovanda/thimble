# frozen_string_literal: true

require 'thimble'

RSpec.describe 'Thimble graceful shutdown' do
  describe Thimble::CancellationToken do
    it 'supports graceful drain followed by immediate escalation' do
      token = described_class.new
      observed = Queue.new
      subscription = token.on_shutdown { |request| observed << request }

      expect(token.drain('deployment')).to be(true)
      graceful = Timeout.timeout(1) { observed.pop }
      expect(graceful).to be_graceful
      expect(token).to be_draining
      expect(token).not_to be_cancelled
      expect(token.checkpoint!).to equal(token)
      expect(token.wait(timeout: 0)).to equal(graceful)

      expect(token.cancel('forced shutdown')).to be(true)
      immediate = Timeout.timeout(1) { observed.pop }
      expect(immediate).to be_immediate
      expect(token).to be_cancelled
      expect { token.checkpoint! }.to raise_error(Thimble::CancelledError, /forced shutdown/)
      expect(subscription.unsubscribe).to be(false)
    end
  end

  describe 'draining a stage' do
    it 'stops root-source ingress and completes every accepted item' do
      token = Thimble::CancellationToken.new
      source_release = Queue.new
      worker_entered = Queue.new
      worker_release = Queue.new
      source = Enumerator.new do |out|
        out << 1
        source_release.pop
        out << 2
      end
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)
      result = Thimble::Thimble.new(source, manager).map_async(cancellation: token) do |value|
        worker_entered << true
        worker_release.pop
        value
      end
      Timeout.timeout(1) { worker_entered.pop }

      expect(result.drain('rolling deploy')).to be(true)
      expect(result).to be_draining
      source_release << true
      worker_release << true

      expect(result.to_a).to eq([1])
      expect(result.wait(timeout: 1)).to equal(result.execution)
      expect(result).to be_drained
      expect(result.shutdown_reason).to eq('rolling deploy')
      expect(result.error).to be_nil
      expect(manager).not_to be_working
    end

    it 'drains connected queue stages under one shared token' do
      token = Thimble::CancellationToken.new
      entered = Queue.new
      release = Queue.new
      first_manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 2, worker_type: :thread)
      second_manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 2, worker_type: :thread)

      intermediate = Thimble::Thimble.new((1..100).to_a, first_manager).map_async(cancellation: token) do |value|
        if value == 1
          entered << true
          release.pop
        end
        value * 2
      end
      output = Thimble::Thimble.new(intermediate, second_manager).map_async(cancellation: token) { |value| value + 1 }
      Timeout.timeout(1) { entered.pop }

      token.drain('pipeline drain')
      release << true
      values = Timeout.timeout(3) { output.to_a }

      expect(values).not_to be_empty
      expect(values).to all(be_odd)
      expect(intermediate.wait(timeout: 1)).to equal(intermediate.execution)
      expect(output.wait(timeout: 1)).to equal(output.execution)
      expect(intermediate).to be_drained
      expect(output).to be_drained
      expect(first_manager).not_to be_working
      expect(second_manager).not_to be_working
    end
  end
end
