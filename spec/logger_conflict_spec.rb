# frozen_string_literal: true

# This test verifies that imprint doesn't shadow Ruby's stdlib Logger.
# ActiveSupport expects Logger::Severity to be available after requiring "logger".
# If imprint shadows stdlib's logger, Rails apps will break.

RSpec.describe "Logger stdlib compatibility" do
  it "does not shadow Ruby's stdlib Logger" do
    # First, require imprint (this is what happens when the gem loads)
    require "imprint"

    # Now require logger - this should give us Ruby's stdlib Logger
    require "logger"

    # ActiveSupport expects Logger::Severity to exist
    # This is what fails in Rails when imprint shadows the stdlib
    expect(defined?(Logger::Severity)).to eq("constant"),
      "Logger::Severity should be defined (stdlib Logger)"

    # Also verify we can access severity constants like ActiveSupport does
    expect { Logger::Severity.constants }.not_to raise_error
  end

  it "does not auto-require traced_logger to avoid boot conflicts" do
    require "imprint"

    # Imprint::Logger should NOT be defined by default
    # Users must explicitly require it if they want it
    expect(defined?(Imprint::Logger)).to be_nil,
      "Imprint::Logger should not be auto-loaded - it must be explicitly required"
  end

  it "allows explicit require of traced_logger without conflicts" do
    require "imprint"
    require "logger" # Ensure stdlib is loaded first
    require "imprint/traced_logger"

    # Now Imprint::Logger should be defined
    expect(defined?(Imprint::Logger)).to eq("constant")

    # And it should inherit from stdlib Logger
    expect(Imprint::Logger.superclass).to eq(::Logger)

    # Stdlib Logger should still work
    expect(defined?(Logger::Severity)).to eq("constant")
  end
end
