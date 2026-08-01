# Thimble

Thimble is a small Ruby runtime for **bounded concurrent pipelines**. It coordinates work across threads or forked processes while keeping queue capacity, batch size, shared worker limits, retries, and shutdown behavior explicit.

The core use case is a pipeline where one stage discovers or reads data, bounded queues limit how much can remain in memory, and downstream stages submit or write work in controlled batches.

## Installation

Add Thimble to your Gemfile:

```ruby
gem 'thimble'
```

Then run:

```shell
bundle install
```

Thimble supports Ruby 3.3, 3.4, and 4.0. Fork workers require a platform that implements `Process.fork`; use thread workers on Windows and other non-forking runtimes.

## Parallel map

```ruby
require 'thimble'

manager = Thimble::Manager.new(
  max_workers: 8,
  batch_size: 25,
  queue_size: 50,
  worker_type: :thread
)

results = Thimble::Thimble
  .new((1..1_000).to_a, manager)
  .map { |value| value * 2 }

p results.to_a
```

`queue_size` is the actual source-queue capacity. The source is enumerated lazily after processing begins, so a large finite input is not copied into an unbounded internal array.

Parallel stages are unordered. Sort results or attach sequence numbers when original order matters.

## Bounded streaming pipeline

Use asynchronous transforms to connect stages without materializing the complete input or output:

```ruby
require 'pathname'
require 'thimble'

paths = Enumerator.new do |out|
  Pathname('incoming').find do |path|
    out << path if path.file?
  end
end

read_manager = Thimble::Manager.new(
  max_workers: 8,
  batch_size: 1,
  queue_size: 16,
  worker_type: :thread
)

contents = Thimble::Thimble
  .new(paths, read_manager)
  .map_async { |path| [path, File.binread(path)] }

submit_manager = Thimble::Manager.new(
  max_workers: 3,
  batch_size: 20,
  queue_size: 6,
  worker_type: :thread
)

responses = Thimble::Thimble
  .new(contents, submit_manager)
  .map_batches_async { |batch| remote_client.submit(batch) }

responses.each { |response| record_response(response) }
```

In this example:

- at most 16 file paths wait in the read-stage input queue;
- at most 6 submission responses wait in the final result queue;
- file contents flow directly into the submission stage;
- each submission receives an array of up to 20 items;
- downstream slowdown propagates back through the pipeline rather than allowing memory growth.

## Item and batch operations

`map` and `map_async` call the block once per item.

`map_batches` and `map_batches_async` call the block once per worker batch:

```ruby
manager = Thimble::Manager.new(
  max_workers: 2,
  batch_size: 100,
  queue_size: 10,
  worker_type: :thread
)

responses = Thimble::Thimble
  .new(events, manager)
  .map_batches_async { |batch| client.bulk_insert(batch) }

responses.each { |response| puts response }
```

The final batch may contain fewer than `batch_size` items.

Synchronous transforms buffer their complete result before returning, so their source must report a finite integer size. Use `map_async` or `map_batches_async` for enumerators, open queues, continuous sources, and other unknown-size streams.

## Execution lifecycle, cancellation, and timeouts

Every transform has a `Thimble::Execution` with an explicit lifecycle:

```text
pending -> running  -> succeeded
                   -> failed
                   -> timed_out
        -> draining -> drained
        -> cancelling -> cancelled
```

Asynchronous result queues expose that execution directly and provide convenience methods such as `state`, `wait`, `drain`, `cancel`, `running?`, `draining?`, `drained?`, `succeeded?`, `cancelled?`, `timed_out?`, and `error`.

```ruby
result = Thimble::Thimble
  .new(events, manager)
  .map_async(timeout: 30, worker_timeout: 5) do |event|
    client.deliver(event)
  end

unless result.wait(timeout: 35)
  result.cancel('caller stopped waiting')
end

raise result.error if result.failed? || result.timed_out?
```

The supervision options are available on `map`, `map_async`, `map_batches`, and `map_batches_async`:

| Option | Meaning |
| --- | --- |
| `timeout` | Deadline for the complete stage, including source enumeration, retry backoff, worker execution, queue waits, and downstream backpressure |
| `worker_timeout` | Maximum runtime for one dispatched worker batch, including its retries and backoff |
| `cancellation` | A shared `Thimble::CancellationToken` used to stop related stages together |

### Graceful drain versus immediate cancellation

A graceful drain stops root-source ingress at the next cooperative boundary while allowing already accepted queue items and active workers to finish:

```ruby
token = Thimble::CancellationToken.new

result = Thimble::Thimble
  .new(source, manager)
  .map_async(cancellation: token) { |item| process(item) }

result.drain('rolling deploy')
result.wait
puts result.state # => :drained
```

When several stages share a token, root enumerable sources stop accepting new work and stages whose source is another `ThimbleQueue` continue draining accepted upstream items. A graceful request does not raise at `token.checkpoint!`.

Immediate cancellation aborts queues, discards buffered results, stops active workers, and raises a `Thimble::CancelledError` through the result queue:

```ruby
token.cancel('forced shutdown')
# or:
result.cancel('forced shutdown')
```

A graceful request may be escalated later by calling `cancel`. External enumerators that are blocked inside their own code remain cooperative; use a stage timeout or `ShutdownCoordinator` grace period when shutdown must eventually become immediate.

## Retries, classification, and dead letters

Retries are opt-in and bounded. `max_attempts` includes the first attempt:

```ruby
policy = Thimble::RetryPolicy.new(
  max_attempts: 4,
  base_delay: 0.1,
  max_delay: 2.0,
  multiplier: 2.0,
  jitter: 0.2,
  retry_on: [IOError, Errno::ECONNRESET],
  abort_on: [ArgumentError]
)

result = Thimble::Thimble
  .new(events, manager)
  .map_async(retry_policy: policy) do |event, attempt|
    logger.info("attempt=#{attempt.attempt} event=#{event.id}")
    client.deliver(event)
  end
```

`retry_policy` accepts a `RetryPolicy`, an integer attempt count, or a hash of `RetryPolicy` options. Backoff is exponential, capped by `max_delay`, and optionally jittered. Immediate cancellation interrupts thread-worker backoff. Graceful drain allows retries for work that was already accepted.

By default, a retry policy matches `StandardError` but rejects common programming and input errors such as `ArgumentError`, `TypeError`, `NameError`, `LocalJumpError`, `FrozenError`, and `ZeroDivisionError`. Supply `retry_on` and `abort_on` exception classes or callables to define workload-specific classification. `abort_on` takes precedence.

When `retry_policy` is supplied, the optional second block argument is a `Thimble::AttemptContext` containing:

- execution name;
- current and maximum attempt numbers;
- item or batch input;
- batch size and batch mode;
- worker type and worker identity;
- attempt start time.

Blocks that declare only one argument, including `&:method_name`, retain their existing behavior.

### Structured final failure

When retry or dead-letter options are enabled, an exhausted final failure raises `Thimble::WorkFailedError`. Its `failure` is a `Thimble::FailureContext`, and the original exception is installed as the Ruby exception cause when available:

```ruby
begin
  result.to_a
rescue Thimble::WorkFailedError => error
  failure = error.failure
  warn "#{failure.input_summary} failed after #{failure.attempt} attempts"
  warn "classification=#{failure.classification} cause=#{error.cause}"
end
```

`FailureContext` records the payload snapshot, error snapshot, attempt count, retry classification, batch metadata, worker identity, timing, and whether retries were exhausted. Thread workers retain the original input and exception. Fork workers retain them when marshalable and otherwise provide class names, bounded summaries, backtraces, and `RemoteWorkerError` reconstruction.

Calls that do not enable retry, dead-letter, or failure-mode options continue raising the original worker exception type for compatibility.

### Dead-letter continuation

A final failure can be sent to a callable, queue, array, or other object supporting `call`, `push`, or `<<`:

```ruby
dead_letters = Queue.new

result = Thimble::Thimble
  .new(events, manager)
  .map_async(
    retry_policy: policy,
    dead_letter: dead_letters,
    failure_mode: :continue
  ) do |event|
    client.deliver(event)
  end
```

`failure_mode: :continue` requires a dead-letter sink so failed work cannot disappear silently. The sink receives one `FailureContext` after classification or retry exhaustion. Without `:continue`, the sink is still notified and the stage then fails.

## Coordinated process-signal shutdown

`Thimble::ShutdownCoordinator` routes process signals through a self-pipe to normal Ruby thread context. The first configured signal requests graceful drain; a repeated signal or expired grace period escalates to immediate cancellation.

```ruby
token = Thimble::CancellationToken.new
shutdown = Thimble::ShutdownCoordinator.new(
  token: token,
  signals: %w[INT TERM],
  grace_period: 15
)

contents = Thimble::Thimble
  .new(paths, read_manager)
  .map_async(cancellation: token) { |path| File.binread(path) }

responses = Thimble::Thimble
  .new(contents, submit_manager)
  .map_batches_async(cancellation: token) { |batch| client.submit(batch) }

shutdown.register(contents, responses).install

begin
  responses.each { |response| record_response(response) }
ensure
  shutdown.close
end
```

Register every execution that must finish during the grace period. `install` and `close` must run on the main Ruby thread because they modify process signal handlers. `close` restores the handlers that were present before installation.

## Manager options

| Option | Meaning |
| --- | --- |
| `max_workers` | Maximum active workers shared by every Thimble using this manager |
| `batch_size` | Items assigned to each worker, or exposed to each `map_batches` call |
| `queue_size` | Capacity of source queues and automatically created asynchronous result queues |
| `worker_type` | `:thread` or `:fork` |

Sharing one manager creates a common concurrency budget:

```ruby
api_budget = Thimble::Manager.new(
  max_workers: 4,
  batch_size: 10,
  queue_size: 20,
  worker_type: :thread
)

first  = Thimble::Thimble.new(first_source, api_budget)
second = Thimble::Thimble.new(second_source, api_budget)

first_results  = first.map_async  { |item| api.call(item) }
second_results = second.map_async { |item| api.call(item) }
```

The two pipelines cannot collectively exceed four active workers.

## ThimbleQueue

`ThimbleQueue` is a bounded multi-producer, multi-consumer queue:

```ruby
queue = Thimble::ThimbleQueue.new(10, 'records')
queue.push(record)
queue.close
queue.each { |item| consume(item) }
```

Important semantics:

- `push` blocks while the queue is full;
- `close` rejects new values and lets consumers drain existing values;
- `close(true)` closes immediately and discards buffered values;
- `abort(error)` closes immediately and raises the error in blocked and future producers and consumers;
- `each`, `next`, and `to_a` consume values destructively;
- for compatibility, `size` and `length` report capacity; use `current_size` for current depth.

## Failure and worker behavior

- Worker exceptions are propagated to synchronous callers.
- Asynchronous failures abort the result queue and are raised when the result is consumed.
- A failed, immediately cancelled, or timed-out stage stops its remaining workers and wakes blocked producers and consumers.
- A gracefully drained stage closes normally after accepted work finishes and reports `:drained` with no execution error.
- `Execution#error`, timestamps, duration, shutdown reason, and terminal state preserve operation context.
- Fork workers are explicitly reaped by the parent, with `TERM` followed by `KILL` escalation for uncooperative children.
- Non-marshallable fork results become a descriptive worker error instead of silently hanging.

## Choosing a worker type

### Threads

Choose threads for file, socket, HTTP, database, and other blocking I/O. Thimble does not modify the process-wide `Thread.abort_on_exception` setting.

### Forks

Choose forks for CPU-bound Ruby on MRI when process isolation and serialization overhead are acceptable. Values crossing the process boundary must be marshalable. Recreate database connections, network clients, and other external resources inside child work rather than sharing them across a fork.

## Development

```shell
bundle install
bundle exec rake
bundle exec gem build thimble.gemspec
```

See [ROADMAP.md](ROADMAP.md) for the next architectural milestones and [CHANGELOG.md](CHANGELOG.md) for release notes.
