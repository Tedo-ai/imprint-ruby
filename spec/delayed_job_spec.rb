# frozen_string_literal: true

require "spec_helper"
require "logger"
require "delayed_job"
require "imprint/delayed_job"

RSpec.describe Imprint::DelayedJob::TracedPayload do
  it "delegates perform to the wrapped payload" do
    payload = instance_double("Payload")
    allow(payload).to receive(:perform).and_return(:ok)

    traced = described_class.new(payload, trace_id: "trace-1", parent_span_id: "span-1")

    expect(traced.perform).to eq(:ok)
    expect(payload).to have_received(:perform)
  end

  it "treats nil payloads as a no-op" do
    traced = described_class.new(nil, trace_id: "trace-1", parent_span_id: "span-1")

    expect { traced.perform }.not_to raise_error
    expect(traced.perform).to be_nil
  end
end

RSpec.describe Imprint::DelayedJob::Plugin do
  describe ".extract_job_name" do
    it "uses a safe fallback name for nil payloads" do
      job = instance_double("Delayed::Job", payload_object: Imprint::DelayedJob::TracedPayload.new(nil))

      expect(described_class.send(:extract_job_name, job)).to eq("UnknownJob#perform")
    end
  end
end
