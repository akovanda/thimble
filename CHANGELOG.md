# Changelog

## Unreleased

### Added

- Bounded lazy source ingestion using `Manager#queue_size`.
- `map_batches` and `map_batches_async` for bulk operations.
- Queue capacity/depth introspection and explicit abort propagation.
- Support and CI coverage for Ruby 3.3, 3.4, and 4.0.
- A documented roadmap for supervised pipelines and persistent executors.
- `CancellationToken` for explicit cancellation shared across connected stages.
- `Execution` lifecycle state, timing, wait, error, and cancellation introspection.
- Complete-stage `timeout` and per-batch `worker_timeout` controls on every map variant.
- Cancellation, lifecycle, and timeout helpers on asynchronous result queues.

### Changed

- Shared worker limits are now reserved atomically across concurrent pipelines.
- Thread and fork worker completion no longer relies on a hot polling loop.
- Thread errors propagate without changing `Thread.abort_on_exception` globally.
- Fork workers are reaped deterministically and non-marshallable results return a clear error.
- Queue close operations wake blocked producers and consumers safely.
- Queue waits now participate in execution cancellation and deadlines without polling.
- Fork cancellation escalates from `TERM` to `KILL` when a child does not exit promptly.
- Runtime support now targets maintained Ruby releases, requiring Ruby 3.3 or newer.

### Removed

- The runtime dependency on `ostruct`.
