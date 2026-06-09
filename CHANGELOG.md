# Changelog

All notable changes to `imprint-ruby` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.2] - 2026-06-09

Follow-up to v0.1.1's async-export fix, addressing review feedback from a
production user (Bidvise) running a Puma preload cluster.

### Fixed
- **Fork safety (critical).** The export worker thread is created at client init
  and does not survive `fork()`. On a preloading server (Puma `preload_app!` +
  workers) the client is built in the master, so every forked worker had a dead
  worker thread and exported nothing — silent telemetry loss. (In v0.1.0 the
  inline `flush_sync` accidentally masked this.) The worker is now **lazily
  (re)started per process** on first enqueue (`ensure_worker_for_process!`),
  resetting inherited queues/wake-state in the child so it never double-sends.
- **Lost-span race on drain.** Replaced the `Concurrent::Array` `to_a` + `clear`
  pair (a concurrent `<<` between the two was wiped) with `Thread::Queue` drained
  by non-blocking pop — each item leaves atomically; a late push rides the next
  flush.

### Changed
- **Wake throttling.** Reaching `batch_size` no longer signals the worker on
  *every* subsequent enqueue (≈700 `@flush_mutex` acquisitions on an 800-span
  request); it now signals at most once per `batch_size` worth of items, plus a
  lock-free fast-path that skips the mutex when a flush is already pending.
- **Chunked drain.** A backlog is now POSTed in `batch_size` chunks instead of
  one oversized body that could exceed the ingest payload limit.

### Added
- Overflow drops are counted (`dropped_spans_count` / `dropped_logs_count`) and
  surfaced in debug logs, so backpressure is visible instead of silent.
- Regression specs: export survives a simulated fork (worker restarts), drain
  chunks oversized backlogs, and overflow increments the drop counters.

Thanks to the Bidvise dev for the detailed PR #2 review and prod trace data.

## [0.1.1] - 2026-06-09

### Fixed
- **Exports no longer block the caller (request) thread.** `Client#queue_span`
  and `Client#queue_log` previously called `flush_sync` inline when the buffer
  reached `batch_size`, so the request thread performed a blocking `Net::HTTP`
  POST to the ingest endpoint (5s open + 5s read timeout). On high-span
  endpoints (e.g. 400–870 spans/request) this meant several synchronous POSTs
  per request and turned ingest slowdowns directly into request latency. Recording
  is now a non-blocking enqueue: reaching `batch_size` signals the background
  worker (via a `ConditionVariable` with a lossless-wake flag), and the worker
  owns all HTTP export. Drop-on-overflow at `buffer_size` is preserved as
  backpressure; synchronous flush happens only at `shutdown`.

### Added
- Regression spec (`spec/async_export_spec.rb`) asserting that export runs off
  the caller thread, that `queue_*` returns immediately under a slow exporter,
  and that the buffer never exceeds `buffer_size`.
- Gem metadata (`source_code_uri`, `changelog_uri`, `bug_tracker_uri`,
  `documentation_uri`, `rubygems_mfa_required`); the gem version is now
  single-sourced from `Imprint::VERSION`.

## [0.1.0]

### Added
- Initial release: automatic instrumentation for Rails, Sidekiq, and
  Delayed::Job with trace context propagation; spans, events, gauges, and logs;
  background worker batching with configurable `batch_size`, `flush_interval`,
  and `buffer_size`.

[Unreleased]: https://github.com/Tedo-ai/imprint-ruby/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Tedo-ai/imprint-ruby/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/Tedo-ai/imprint-ruby/releases/tag/v0.1.0
