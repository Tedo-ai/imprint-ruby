# frozen_string_literal: true

# This test verifies that imprint doesn't shadow Ruby's stdlib Logger.
# ActiveSupport expects Logger::Severity to be available after requiring "logger".
# If imprint/logger.rb shadows stdlib's logger, Rails apps will break.

RSpec.describe "Logger stdlib compatibility" do
  it "does not shadow Ruby's stdlib Logger" do
    # Simulate a fresh require (clear any cached requires)
    # In a real scenario, this happens during Rails boot

    # First, require imprint (this is what happens when the gem loads)
    require "imprint"

    # Now require logger - this should give us Ruby's stdlib Logger
    require "logger"

    # ActiveSupport expects Logger::Severity to exist
    # This is what fails in Rails when imprint shadows the stdlib
    expect(defined?(Logger::Severity)).to eq("constant"),
      "Logger::Severity should be defined (stdlib Logger), but imprint/logger.rb may be shadowing it"

    # Also verify we can access severity constants like ActiveSupport does
    expect { Logger::Severity.constants }.not_to raise_error
  end
end
