# frozen_string_literal: true

require "spec_helper"
require "rack/mock"
require "imprint"
require "imprint/rails/middleware"

RSpec.describe Imprint::Rails::Middleware do
  let(:client) { instance_double(Imprint::Client) }
  let(:span) { instance_double(Imprint::Span, span_id: "span-123") }

  before do
    Imprint.configure do |config|
      config.service_name = "spec-service"
      config.enabled = false
    end

    allow(Imprint).to receive(:client).and_return(client)
    allow(Imprint.configuration).to receive(:should_ignore?).and_return(false)
    allow(Imprint::Span).to receive(:generate_trace_id).and_return("trace-123")
    allow(Imprint::Span).to receive(:generate_span_id).and_return("span-123")
    allow(Imprint::Span).to receive(:new).and_return(span)
    allow(Imprint::Context).to receive(:with_span).and_yield

    allow(span).to receive(:set_attribute)
    allow(span).to receive(:set_status)
    allow(span).to receive(:record_error)
    allow(span).to receive(:finish)
  end

  it "records request metadata on error before re-raising" do
    app = lambda do |_env|
      raise StandardError, "boom"
    end

    middleware = described_class.new(app)
    env = Rack::MockRequest.env_for("https://example.com/orders/123", method: "GET")

    expect { middleware.call(env) }.to raise_error(StandardError, "boom")

    expect(span).to have_received(:set_attribute).with("http.method", "GET")
    expect(span).to have_received(:set_attribute).with("http.url", "https://example.com/orders/123")
    expect(span).to have_received(:set_attribute).with("http.status_code", 500)
    expect(span).to have_received(:set_status).with(500)
    expect(span).to have_received(:record_error).with(instance_of(StandardError))
    expect(span).to have_received(:finish)
  end
end
