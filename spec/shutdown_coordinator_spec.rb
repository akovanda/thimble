# frozen_string_literal: true

require 'thimble'

RSpec.describe Thimble::ShutdownCoordinator do
  it 'requests graceful drain on the first notification and immediate cancellation on the second' do
    token = Thimble::CancellationToken.new
    coordinator = described_class.new(token: token, signals: ['TERM'], grace_period: nil)

    expect(coordinator.notify('TERM')).to be(true)
    expect(token).to be_draining
    expect(token.reason).to include('SIGTERM')

    expect(coordinator.notify(:term)).to be(true)
    expect(token).to be_cancelled
    expect(token.error).to be_a(Thimble::CancelledError)
  ensure
    coordinator&.close
  end

  it 'escalates when registered executions exceed the grace period' do
    token = Thimble::CancellationToken.new
    execution = Thimble::Execution.new(name: 'hung stage', token: token).start!
    coordinator = described_class.new(token: token, signals: ['TERM'], grace_period: 0.03)
    coordinator.register(execution)

    coordinator.notify('TERM')
    error = token.wait_for_cancel(timeout: 1)

    expect(error).to be_a(Thimble::ShutdownTimeoutError)
    expect(error.grace_period).to eq(0.03)
    execution.fail!(error)
  ensure
    coordinator&.close
  end

  it 'does not escalate after every registered execution finishes draining' do
    token = Thimble::CancellationToken.new
    execution = Thimble::Execution.new(name: 'short stage', token: token).start!
    coordinator = described_class.new(token: token, signals: ['TERM'], grace_period: 0.1)
    coordinator.register(execution)

    coordinator.notify('TERM')
    execution.succeed!

    expect(token.wait_for_cancel(timeout: 0.15)).to be_nil
    expect(execution).to be_drained
    expect(token).to be_draining
    expect(token).not_to be_cancelled
  ensure
    coordinator&.close
  end

  it 'routes installed process signals through a self-pipe and restores handlers' do
    skip 'USR1 is unavailable on this platform' unless Signal.list.key?('USR1')

    token = Thimble::CancellationToken.new
    coordinator = described_class.new(token: token, signals: ['USR1'], grace_period: nil)
    coordinator.install

    Process.kill('USR1', Process.pid)

    request = token.wait_for_shutdown(timeout: 1)
    expect(request).to be_graceful
    expect(request.reason).to include('SIGUSR1')
  ensure
    coordinator&.close
  end

  it 'validates targets, signals, and grace periods' do
    expect { described_class.new(signals: []) }.to raise_error(ArgumentError, /at least one/)
    expect { described_class.new(signals: ['NOT_A_SIGNAL']) }.to raise_error(ArgumentError, /unsupported/)
    expect { described_class.new(grace_period: 0) }.to raise_error(ArgumentError, /grace_period/)

    coordinator = described_class.new(signals: ['TERM'], grace_period: nil)
    expect { coordinator.register(Object.new) }.to raise_error(ArgumentError, /Execution/)
    expect { coordinator.notify('INT') }.to raise_error(ArgumentError, /configured/)

    coordinator.notify('TERM')
    execution = Thimble::Execution.new(name: 'late', token: coordinator.token)
    expect { coordinator.register(execution) }.to raise_error(RuntimeError, /after shutdown/)
  ensure
    coordinator&.close
  end
end
