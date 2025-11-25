# frozen_string_literal: true

require "spec_helper"
require "imprint"

RSpec.describe "Logger stdlib compatibility" do
  it "does not shadow Ruby's stdlib Logger" do
    require "imprint"
    require "logger"

    # ActiveSupport expects Logger::Severity to exist
    expect(defined?(Logger::Severity)).to eq("constant"),
      "Logger::Severity should be defined (stdlib Logger)"

    expect { Logger::Severity.constants }.not_to raise_error
  end

  it "does not auto-require Imprint::Logger to avoid boot conflicts" do
    require "imprint"

    # Imprint::Logger should NOT be defined by default
    expect(defined?(Imprint::Logger)).to be_nil,
      "Imprint::Logger should not be auto-loaded"
  end

  it "allows explicit require of Imprint::Logger" do
    require "imprint"
    require "logger"
    require "imprint/log"

    expect(defined?(Imprint::Logger)).to eq("constant")
    expect(Imprint::Logger.superclass).to eq(::Logger)
  end
end

RSpec.describe "Imprint::Logger" do
  before do
    require "imprint/log"

    Imprint.configure do |config|
      config.api_key = "test_key"
      config.ingest_url = "http://localhost:8080"
      config.enabled = false # Don't actually send
    end
  end

  describe "#initialize" do
    it "accepts a group name" do
      logger = Imprint::Logger.new("rails")
      expect(logger.group).to eq("rails")
    end

    it "accepts default attributes" do
      logger = Imprint::Logger.new("app", attributes: { customer_id: 123 })
      expect(logger.default_attributes).to eq({ "customer_id" => 123 })
    end

    it "accepts a format option" do
      logger = Imprint::Logger.new("app", format: Imprint::Logger::LOGFMT)
      expect(logger.format).to eq(:logfmt)
    end
  end

  describe "#broadcast_to" do
    it "adds a logger to broadcast targets" do
      logger = Imprint::Logger.new("app")
      other_logger = Logger.new($stdout)

      logger.broadcast_to(other_logger)

      expect(logger.broadcast_targets).to include(other_logger)
    end

    it "returns self for chaining" do
      logger = Imprint::Logger.new("app")
      result = logger.broadcast_to(Logger.new($stdout))

      expect(result).to eq(logger)
    end
  end

  describe "logging methods" do
    let(:logger) { Imprint::Logger.new("test") }

    it "supports info with attributes" do
      expect { logger.info("test message", user_id: 123) }.not_to raise_error
    end

    it "supports warn with attributes" do
      expect { logger.warn("warning", code: "W001") }.not_to raise_error
    end

    it "supports error with attributes" do
      expect { logger.error("error occurred", error_class: "RuntimeError") }.not_to raise_error
    end

    it "supports block form" do
      expect { logger.info { "computed message" } }.not_to raise_error
    end
  end

  describe "format detection" do
    let(:logger) { Imprint::Logger.new("test") }

    it "detects JSON format" do
      # Just verify it doesn't raise
      expect { logger.info('{"key": "value", "message": "test"}') }.not_to raise_error
    end

    it "detects logfmt format" do
      expect { logger.info("level=info category=test This is a message") }.not_to raise_error
    end

    it "handles plaintext" do
      expect { logger.info("Just a plain message") }.not_to raise_error
    end
  end
end
