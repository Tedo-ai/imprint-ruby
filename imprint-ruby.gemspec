# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name          = "imprint-ruby"
  spec.version       = "0.1.0"
  spec.authors       = ["Imprint"]
  spec.email         = ["support@imprint.dev"]

  spec.summary       = "Ruby agent for Imprint observability platform"
  spec.description   = "Automatic instrumentation for Rails, Sidekiq, and Delayed::Job with trace propagation"
  spec.homepage      = "https://github.com/tedo-ai/imprint-ruby"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.0.0"

  spec.files         = Dir["lib/**/*", "LICENSE", "README.md"]
  spec.require_paths = ["lib"]

  spec.add_dependency "concurrent-ruby", "~> 1.0"
  spec.add_dependency "ostruct"  # Required for Ruby 3.5+

  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "webmock", "~> 3.0"
end
