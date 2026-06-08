# frozen_string_literal: true

require_relative "lib/imprint/version"

Gem::Specification.new do |spec|
  spec.name          = "imprint-ruby"
  spec.version       = Imprint::VERSION
  spec.authors       = ["Imprint"]
  spec.email         = ["support@imprint.dev"]

  spec.summary       = "Ruby agent for Imprint observability platform"
  spec.description   = "Automatic instrumentation for Rails, Sidekiq, and Delayed::Job with trace propagation"
  spec.homepage      = "https://github.com/Tedo-ai/imprint-ruby"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 2.7.0"

  spec.metadata = {
    "source_code_uri"       => "https://github.com/Tedo-ai/imprint-ruby",
    "changelog_uri"         => "https://github.com/Tedo-ai/imprint-ruby/blob/main/CHANGELOG.md",
    "bug_tracker_uri"       => "https://github.com/Tedo-ai/imprint-ruby/issues",
    "documentation_uri"     => "https://docs.imprint.cloud",
    "rubygems_mfa_required" => "true"
  }

  spec.files         = Dir["lib/**/*", "CHANGELOG.md", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "concurrent-ruby", "~> 1.0"
  spec.add_dependency "ostruct", ">= 0.3"  # Becomes a bundled (non-default) gem in Ruby 3.5+

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.0"
end
