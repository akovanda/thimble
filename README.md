# Thimble
Thimble is a Ruby gem for parallelism and concurrency. It lets you choose threads (good for IO) or processes (good for CPU) and build pipelines using stages backed by a thread-safe queue.

---

## Installation
Add this line to your application's Gemfile:

```
gem 'thimble'
```

And then execute:

```
bundle install
```

Or install it yourself as:

```
gem install thimble
```

## Supported Ruby and platforms
- Ruby >= 3.0
- MRI: threads are limited by the GVL for CPU-bound work. Use `worker_type: :fork` for CPU-bound pipelines.
- JRuby/TruffleRuby: threads can run in parallel; `:thread` often suffices.
- Windows: `fork` is not available. Use `worker_type: :thread`.

## Quick start

Example 1: parallel map using forked processes (CPU-bound)
```
require 'thimble'

manager = Thimble::Manager.new(max_workers: 5, batch_size: 5, queue_size: 10, worker_type: :fork)
thimble = Thimble::Thimble.new((1..100).to_a, manager)
results = thimble.map { |x| x * 1000 }
# results is a Thimble::ThimbleQueue; consume it as needed
p results.to_a
```

Example 2: feed an intermediate queue from a threaded stage (IO-bound)
```
require 'thimble'
# We create a queue to store intermediate work
queue = Thimble::ThimbleQueue.new(3, 'stage 2')
# Our array of data
ary = (1..10).to_a
# A separate thread worker who will be processing the intermediate queue
thread = Thimble::Thimble.async do
  queue.each { |x| puts "I did work on #{x}!"; sleep 1 }
end
# Our Thimble, plus its manager. Note we are using Thread in this example.
thim = Thimble::Thimble.new(ary, Thimble::Manager.new(batch_size: 1, worker_type: :thread))
# We in parallel push data to the Thimble Queue
thim.map { |e| queue.push(e); sleep 0.1; puts "I pushed #{e} to the queue!" }
# The queue is closed (no more work can come in)
queue.close
# join the thread
thread.join
```

Manager quick reference
```
m = Thimble::Manager.new(max_workers: 10, batch_size: 100, worker_type: :fork)
Thimble::Thimble.new(array, m)
```
- max_workers: how many workers can run at the same time
- batch_size: how many items to send to each worker (tune for workload)
- worker_type: :thread or :fork

The same Manager can be shared across Thimble instances to coordinate concurrency limits.

All thimbles require an explicit manager.

---

## ThimbleQueue
ThimbleQueue is the queue underpinning Thimble. Taking from it is destructive. It is thread-safe for multi-thread producers/consumers.

```
q = Thimble::ThimbleQueue.new(10, 'name')
q.push(1)
q.close
q.each { |x| puts x }
# => 1
```
If you do not close the queue, consumers will wait for more data. Creating a Thimble creates a "closed" input queue; transformations create a new queue.

---

## Caveats and best practices
These are common pitfalls and how Thimble helps you avoid them:

- MRI GVL and workload choice
  - Threads do not run CPU-bound Ruby in parallel on MRI. Use `worker_type: :fork` for CPU-bound tasks; `:thread` shines for IO-bound tasks.
- Platform differences
  - `fork` is Unix-only. On Windows, use `:thread`.
- Forking and safety
  - Thimble forks child workers before creating additional threads inside children. Children trap HUP and exit cleanly; the parent detaches workers to avoid zombies.
  - Recreate external resources in children (DB connections, sockets, clients). Don’t share them across a fork.
- Memory and copy-on-write
  - Each process has its own heap and GC. Batching reduces IPC overhead. Freeze large constants to improve CoW where possible.
- Backpressure
  - ThimbleQueue is bounded; tune `queue_size` to avoid unbounded growth.
- Shutdown
  - ThimbleQueue supports `close` and `close(true)` for immediate close. Avoid closing from multiple places.
- Error propagation
  - Exceptions in workers are propagated back through results. For `:thread`, thread exceptions are surfaced; for `:fork`, exceptions are marshaled back and re-raised when consumed.
- Signal handling
  - The main process receives signals; Thimble sends HUP to child workers when their results are consumed.
- Ordering
  - Parallel stages may reorder results. If you need original order, attach sequence numbers to items and reorder at the end.
- Tuning
  - Start with `max_workers` ~ number of cores for CPU-bound, higher for IO-bound. Adjust `batch_size` to minimize overhead without starving workers.

---

## Development
- Run tests: `bundle exec rspec`
- Linting: consider adding RuboCop (`rubocop`)
- Releasing: bump `Thimble::VERSION` in `lib/thimble/version.rb`, tag and push, then build and push the gem

Contributions welcome! Please open issues and PRs.
