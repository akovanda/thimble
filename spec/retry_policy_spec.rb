# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble::RetryPolicy do
  describe 'configuration and classification' do
    it 'calculates bounded exponential backoff with deterministic jitter' do
      random = Class.new do
        def rand
          0.5
        end
      end.new
      policy = described_class.new(
        max_attempts: 5,
        base_delay: 0.25,
        max_delay: 1.0,
        multiplier: 2.0,
        jitter: 0.4
      )

      expect(policy.delay_for(1, random: random)).to eq(0.25)
      expect(policy.delay_for(2, random: random)).to eq(0.5)
      expect(policy.delay_for(3, random: random)).to eq(1.0)
      expect(policy.delay_for(4, random: random)).to eq(1.0)
    end

    it 'applies abort classifiers before retry classifiers' do
      policy = described_class.new(
        max_attempts: 3,
        retry_on: StandardError,
        abort_on: [ArgumentError, ->(error, _context) { error.message == 'permanent' }]
      )

      expect(policy.retryable?(IOError.new('temporary'))).to be(true)
      expect(policy.retryable?(ArgumentError.new('temporary'))).to be(false)
      expect(policy.retryable?(IOError.new('permanent'))).to be(false)
      expect(policy.retryable?(Thimble::CancelledError.new)).to be(false)
    end

    it 'validates bounded retry settings' do
      expect { described_class.new(max_attempts: 0) }.to raise_error(ArgumentError, /max_attempts/)
      expect do
        described_class.new(max_attempts: 2, base_delay: 2, max_delay: 1)
      end.to raise_error(ArgumentError, /max_delay/)
      expect { described_class.new(max_attempts: 2, jitter: 2) }.to raise_error(ArgumentError, /jitter/)
      expect do
        described_class.new(max_attempts: 2, retry_on: Object.new)
      end.to raise_error(ArgumentError, /retry_on/)
    end
  end

  describe 'supervised retry execution' do
    it 'retries individual items and supplies attempt context to the block' do
      attempts = Hash.new(0)
      contexts = Queue.new
      manager = Thimble::Manager.new(max_workers: 2, batch_size: 1, queue_size: 2, worker_type: :thread)
      policy = described_class.new(max_attempts: 3, base_delay: 0)

      result = Thimble::Thimble.new([1, 2], manager).map(retry_policy: policy) do |value, context|
        contexts << context
        attempts[value] += 1
        raise IOError, 'temporary' if attempts[value] == 1

        value * 10
      end

      expect(result.to_a).to contain_exactly(10, 20)
      expect(attempts).to eq(1 => 2, 2 => 2)
      observed = 4.times.map { Timeout.timeout(1) { contexts.pop } }
      expect(observed.map(&:attempt).sort).to eq([1, 1, 2, 2])
      expect(observed).to all(be_a(Thimble::AttemptContext))
      expect(observed).to all(have_attributes(max_attempts: 3, batch_size: 1, worker_type: :thread))
      expect(observed.map(&:worker_id)).to all(be_a(Integer))
    end

    it 'retries a whole batch as one operation' do
      attempts = 0
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 3, queue_size: 2, worker_type: :thread)

      result = Thimble::Thimble.new((1..3).to_a, manager).map_batches(retry_policy: 2) do |batch, context|
        attempts += 1
        raise IOError, 'temporary' if context.first_attempt?

        batch.sum
      end

      expect(result.to_a).to eq([6])
      expect(attempts).to eq(2)
    end

    it 'raises structured failure context after retries are exhausted' do
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)

      expect do
        Thimble::Thimble.new([7], manager).map(retry_policy: 2) do
          raise IOError, 'service unavailable'
        end.to_a
      end.to raise_error(Thimble::WorkFailedError) { |error|
        expect(error.cause).to be_a(IOError)
        expect(error.failure).to have_attributes(
          input: 7,
          attempt: 2,
          max_attempts: 2,
          retryable: true,
          exhausted: true,
          classification: :retry_exhausted,
          batch_size: 1,
          worker_type: :thread
        )
      }
    end

    it 'routes final failures to a dead-letter sink and continues explicitly' do
      dead_letters = []
      manager = Thimble::Manager.new(max_workers: 2, batch_size: 1, queue_size: 2, worker_type: :thread)

      result = Thimble::Thimble.new([1, 2, 3], manager).map(
        retry_policy: { max_attempts: 2, base_delay: 0 },
        dead_letter: dead_letters,
        failure_mode: :continue
      ) do |value|
        raise IOError, 'permanent' if value == 2

        value
      end

      expect(result.to_a).to contain_exactly(1, 3)
      expect(dead_letters.length).to eq(1)
      expect(dead_letters.first).to have_attributes(
        input: 2,
        attempt: 2,
        classification: :retry_exhausted
      )
      expect(dead_letters.first.error).to be_a(IOError)
    end

    it 'does not retry errors rejected by the classifier' do
      dead_letters = []
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)
      policy = described_class.new(max_attempts: 5, retry_on: IOError, abort_on: ArgumentError)

      Thimble::Thimble.new([1], manager).map(
        retry_policy: policy,
        dead_letter: dead_letters,
        failure_mode: :continue
      ) { raise ArgumentError, 'invalid input' }.to_a

      expect(dead_letters.first).to have_attributes(
        attempt: 1,
        retryable: false,
        exhausted: false,
        classification: :non_retryable
      )
    end

    it 'preserves legacy exception types when retry and dead-letter options are absent' do
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)

      expect do
        Thimble::Thimble.new([1], manager).map(&:missing_method).to_a
      end.to raise_error(NoMethodError, /missing_method/)
    end

    it 'does not add attempt context to legacy splat blocks unless retries are enabled' do
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)

      legacy = Thimble::Thimble.new([1], manager).map { |*arguments| arguments }.to_a
      retried = Thimble::Thimble.new([1], manager).map(retry_policy: 1) { |*arguments| arguments }.to_a

      expect(legacy).to eq([[1]])
      expect(retried.first.length).to eq(2)
      expect(retried.first.last).to be_a(Thimble::AttemptContext)
    end

    it 'supervises blocking dead-letter callbacks with the stage deadline' do
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)
      result = Thimble::Thimble.new([1], manager).map_async(
        timeout: 0.05,
        retry_policy: 1,
        dead_letter: ->(_failure) { Queue.new.pop },
        failure_mode: :continue
      ) { raise IOError, 'failed' }

      expect { result.to_a }.to raise_error(Thimble::StageTimeoutError)
      expect(result.wait(timeout: 1)).to equal(result.execution)
      expect(result).to be_timed_out
      expect(manager).not_to be_working
    end

    it 'interrupts retry backoff on immediate cancellation' do
      token = Thimble::CancellationToken.new
      attempted = Queue.new
      policy = described_class.new(max_attempts: 100, base_delay: 10, max_delay: 10)
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :thread)
      result = Thimble::Thimble.new([1], manager).map_async(
        cancellation: token,
        retry_policy: policy
      ) do
        attempted << true
        raise IOError, 'temporary'
      end
      Timeout.timeout(1) { attempted.pop }

      token.cancel('stop retries')

      expect { result.to_a }.to raise_error(Thimble::CancelledError, /stop retries/)
      expect(result.wait(timeout: 1)).to equal(result.execution)
      expect(manager).not_to be_working
    end

    it 'requires a dead-letter sink before failures may be continued' do
      manager = Thimble::Manager.new(worker_type: :thread)

      expect do
        Thimble::Thimble.new([1], manager).map(failure_mode: :continue) { |value| value }
      end.to raise_error(ArgumentError, /dead_letter/)
    end

    it 'marshals structured failure context from fork workers' do
      skip 'fork is not available on this platform' unless Process.respond_to?(:fork)

      dead_letters = []
      manager = Thimble::Manager.new(max_workers: 1, batch_size: 1, queue_size: 1, worker_type: :fork)
      input = proc {}

      result = Thimble::Thimble.new([input], manager).map(
        retry_policy: 1,
        dead_letter: dead_letters,
        failure_mode: :continue
      ) { raise IOError, 'remote failure' }

      expect(result.to_a).to eq([])
      expect(dead_letters.first).to have_attributes(worker_type: :fork, input_class: 'Proc')
      expect(dead_letters.first.input).to be_nil
      expect(dead_letters.first).not_to be_input_available
      expect(dead_letters.first.input_summary).to include('Proc')
      expect(dead_letters.first.error).to be_a(IOError)
      expect(manager).not_to be_working
    end
  end
end
