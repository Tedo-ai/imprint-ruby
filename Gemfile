# frozen_string_literal: true

source "https://rubygems.org"

gemspec

group :development, :test do
  gem "rake", "~> 13.0"
  gem "rspec", "~> 3.0"
  gem "webmock", "~> 3.0"
  gem "rubocop", "~> 1.0"
end

# Optional dependencies for testing integrations
group :test do
  gem "rails", "~> 7.0"
  gem "sidekiq", "~> 7.0"
  gem "delayed_job", "~> 4.1"
  gem "delayed_job_active_record", "~> 4.1"
end
