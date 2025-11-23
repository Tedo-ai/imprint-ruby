# frozen_string_literal: true

# For development/demo purposes, we use a hardcoded secret key base
# In production, use RAILS_MASTER_KEY or credentials.yml.enc

unless Rails.application.secret_key_base.present?
  Rails.application.config.secret_key_base = ENV.fetch("SECRET_KEY_BASE") {
    "demo_secret_key_base_" + "a" * 100
  }
end
