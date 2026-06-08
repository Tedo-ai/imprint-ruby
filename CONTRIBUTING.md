# Contributing to imprint-ruby

Thanks for helping improve the Imprint Ruby agent.

## Development

```bash
bundle install
bundle exec rspec        # run the test suite
bundle exec rubocop      # lint (if configured)
```

## Guidelines

This SDK follows the shared **Imprint SDK Repo & Release Standards**
(`imprint-internal/docs/sdk-repo-standards.md`). In particular:

- **Async export is non-negotiable.** Recording a span/log/metric must never
  perform network I/O on the caller (request) thread — enqueue only; the
  background worker owns all HTTP. See the "Async Export Rule" in the README and
  `imprint-internal/docs/sdk-async-export-rule.md`. Any change to the buffering/
  export path must keep `spec/async_export_spec.rb` green.
- **Instrumentation must fail safe** — never raise into the host application.
- Follow [SemVer](https://semver.org); the version is single-sourced in
  `lib/imprint/version.rb` and read by the gemspec.

## Submitting changes

1. Branch, make the change, add/adjust specs, keep CI green.
2. Add a `CHANGELOG.md` entry under `[Unreleased]`.
3. Open a PR. A maintainer (oss/imprint) reviews before merge.

## Releasing

See the release checklist in `imprint-internal/docs/sdk-repo-standards.md`:
bump `lib/imprint/version.rb`, move the CHANGELOG entry out of `[Unreleased]`
with a date, tag `vX.Y.Z`, and `gem push`.
