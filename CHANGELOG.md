# Changelog

All notable changes to `imprint-ruby` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
