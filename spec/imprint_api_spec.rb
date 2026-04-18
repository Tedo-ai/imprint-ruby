# frozen_string_literal: true

require "spec_helper"
require "imprint"

RSpec.describe Imprint do
  describe ".set_tag" do
    let(:client) { instance_double(Imprint::Client, enabled?: true) }
    let(:span) do
      Imprint::Span.new(
        trace_id: "trace123",
        span_id: "span123",
        namespace: "spec-service",
        name: "request",
        kind: "server",
        client: nil
      )
    end

    before do
      allow(Imprint).to receive(:client).and_return(client)
      Imprint::Context.current_span = span
    end

    after do
      Imprint::Context.clear!
    end

    it "accepts key-value arguments" do
      Imprint.set_tag(:user_id, 42)

      expect(span.attributes["user_id"]).to eq("42")
    end

    it "accepts hash arguments" do
      Imprint.set_tag(user_id: 42, plan: "premium")

      expect(span.attributes).to include(
        "user_id" => "42",
        "plan" => "premium"
      )
    end
  end
end
