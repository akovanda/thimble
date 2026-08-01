# Thimble Roadmap

Thimble is being developed as a bounded pipeline runtime rather than a generic replacement for `Enumerable#map`.

## Current foundation

- bounded input and asynchronous result queues;
- item and batch transforms;
- shared concurrency budgets;
- thread and fork execution;
- explicit worker failure propagation;
- deterministic close, abort, and process-reaping behavior;
- explicit execution lifecycle states and timing context;
- shared cooperative cancellation tokens;
- complete-stage and per-worker timeouts;
- cancellation propagation through blocked queues and connected stages;
- graceful drain with explicit immediate-cancellation escalation;
- bounded exponential retry policies with jitter and exception classification;
- item, batch, attempt, and final-failure context;
- dead-letter hooks with explicit continue-versus-fail behavior;
- signal-safe shutdown coordination with grace-period escalation.

## Next: first-class stages and pipeline composition

- `source`, `map`, `filter`, `flat_map`, `batch`, and `sink` stages;
- batching by item count, estimated bytes, elapsed time, and grouping key;
- a pipeline builder that owns stage startup, dependency order, and coordinated shutdown;
- ordered and unordered result modes;
- named resource limits for disk, network, API, and CPU budgets;
- preserve the existing low-level `Thimble` and `ThimbleQueue` APIs as building blocks.

## Next: persistent executors

- persistent thread pools rather than one thread per worker batch;
- supervised process pools rather than one fork per worker batch;
- startup and shutdown hooks for external resources;
- framed process IPC and configurable serializers;
- process crash replacement and optional worker recycling.

## Later: observability and alternate runtimes

- event subscriptions for queue depth, wait time, worker utilization, retries, dead letters, and failures;
- adapters for structured logging and OpenTelemetry;
- benchmark and allocation suites;
- Fiber-scheduler integration for compatible I/O clients;
- experimental Ractor support only where shareability constraints produce a clear benefit.

## Non-goals for the near term

- durable or distributed job storage;
- replacing Sidekiq, Active Job, or message brokers;
- hiding backpressure, retries, or shutdown behavior behind implicit global configuration.
