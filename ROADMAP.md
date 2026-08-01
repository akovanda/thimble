# Thimble Roadmap

Thimble is being developed as a bounded pipeline runtime rather than a generic replacement for `Enumerable#map`.

## Current foundation

- bounded input and asynchronous result queues;
- item and batch transforms;
- shared concurrency budgets;
- thread and fork execution;
- explicit worker failure propagation;
- deterministic close, abort, and process-reaping behavior.

## Next: pipeline supervision

- explicit pipeline lifecycle states;
- cooperative cancellation tokens;
- stage and worker timeouts;
- graceful versus immediate shutdown;
- retry policies with bounded backoff;
- structured success and failure context.

## Next: first-class stages

- `source`, `map`, `filter`, `flat_map`, `batch`, and `sink` stages;
- batching by item count, estimated bytes, elapsed time, and grouping key;
- ordered and unordered result modes;
- named resource limits for disk, network, API, and CPU budgets;
- a pipeline builder that preserves the existing low-level API.

## Next: persistent executors

- persistent thread pools rather than one thread per worker batch;
- supervised process pools rather than one fork per worker batch;
- startup and shutdown hooks for external resources;
- framed process IPC and configurable serializers;
- process crash replacement and optional worker recycling.

## Later: observability and alternate runtimes

- event subscriptions for queue depth, wait time, worker utilization, retries, and failures;
- adapters for structured logging and OpenTelemetry;
- benchmark and allocation suites;
- Fiber-scheduler integration for compatible I/O clients;
- experimental Ractor support only where shareability constraints produce a clear benefit.

## Non-goals for the near term

- durable or distributed job storage;
- replacing Sidekiq, Active Job, or message brokers;
- hiding backpressure or retry behavior behind implicit global configuration.
