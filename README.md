# Thimble

Thimble is a small Ruby runtime for **bounded concurrent pipelines**. It coordinates work across threads or forked processes while keeping queue capacity, batch size, and shared worker limits explicit.

The core use case is a pipeline where one stage discovers or reads data, a bounded queue limits how much can remain in memory, and another stage submits or writes work in controlled batches.

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

`queue_size` is the real capacity of the source queue. The source is enumerated lazily after processing starts, so a large finite input is not copied into an unbounded internal array.

Parallel stages are unordered. Sort or attach sequence numbers when the original order matters.

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
- downstream slowdown propagates back through the pipeline instead of allowing memory growth.

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

## Supervision, cancellation, and timeouts

Every transform has a `Thimble::Execution` with an explicit lifecycle:

```text
pending -> running -> succeeded
                   -> failed
                   -> cancelled
                   -> timed_out
```

Asynchronous result queues expose that execution directly and provide convenience methods such as `state`, `wait`, `cancel`, `running?`, `succeeded?`, `cancelled?`, `timed_out?`, and `error`.

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
| `timeout` | Deadline for the complete stage, including source enumeration, worker execution, queue waits, and downstream backpressure |
| `worker_timeout` | Maximum runtime for one dispatched worker batch |
| `cancellation` | A shared `Thimble::CancellationToken` used to cancel related stages together |

A shared cancellation token provides pipeline-wide cancellation without global state:

```ruby
token = Thimble::CancellationToken.new

contents = Thimble::Thimble
  .new(paths, read_manager)
  .map_async(cancellation: token) { |path| File.binread(path) }

responses = Thimble::Thimble
  .new(contents, submit_manager)
  .map_batches_async(cancellation: token) { |batch| client.submit(batch) }

# From a signal handler coordinator, request handler, or shutdown path:
token.cancel('service shutdown')
```

Cancellation and timeout failures abort connected queues, wake blocked producers and consumers, stop active workers, and surface through the asynchronous result queue. Thread-worker blocks that perform long loops can capture the shared token and call token.checkpoint!` for cooperative cancellation. Fork workers cannot observe token changes made after the fork, so the parent terminates and reaps them when cancellation or a timeout occurs.

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

`ThimbleQueue is a bounded multi-producer, multi-consumer queue:

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

## Failure behavior

- Worker exceptions are propagated to synchronous callers.
- Asynchronous failures abort the result queue and are raised when the result is consumed.
- A failed, cancelled, or timed-out stage stops its remaining workers and wakes blocked producers and consumers.
- `Execution#error`, timestamps, duration, and terminal state preserve structured operation context.
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
