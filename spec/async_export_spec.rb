# frozen_string_literal: true

require "spec_helper"
require "securerandom"
require "timeout"
require "imprint"

# Regression: exports must never run on the caller (request) thread. Reaching
# batch_size signals the background worker; the worker owns all HTTP. See the
# ASYNC EXPORT RULE in the README + imprint SDK docs.
RSpec.describe Imprint::Client do
  let(:config) do
    Imprint::Configuration.new.tap do |c|
      c.api_key = "test-key"
      c.ingest_url = "http://127.0.0.1:9/v1/spans"
      c.service_name = "spec"
      c.batch_size = 5
      c.flush_interval = 60 # long: only the batch signal should trigger a flush
      c.enabled = true
      c.debug = false
    end
  end

  let(:client) { described_class.new(config) }

  after { client.shutdown(timeout: 1) }

  def make_span
    Imprint::Span.new(
      trace_id: "trace",
      span_id: SecureRandom.hex(8),
      namespace: "spec",
      name: "work",
      kind: "internal",
      client: client
    )
  end

  it "exports on the worker thread, not the caller thread, when batch_size is reached" do
    caller_thread = Thread.current
    export_threads = Queue.new
    allow(client).to receive(:send_batch) { export_threads << Thread.current }

    config.batch_size.times { client.queue_span(make_span) }

    exporting_thread = Timeout.timeout(5) { export_threads.pop }
    expect(exporting_thread).not_to eq(caller_thread)
  end

  it "does not block the caller: queue_span returns immediately even if export is slow" do
    allow(client).to receive(:send_batch) { sleep 1.0 } # simulate slow/over-loaded ingest

    elapsed = measure { config.batch_size.times { client.queue_span(make_span) } }

    # If queue_span exported inline (the bug), this would take ~1s. Async = fast.
    expect(elapsed).to be < 0.2
  end

  it "drops on overflow instead of growing unbounded (backpressure)" do
    allow(client).to receive(:send_batch) # swallow
    config.buffer_size = 10
    (config.buffer_size + 50).times { client.queue_span(make_span) }
    # No exception, no unbounded growth: the buffer never exceeds buffer_size.
    expect(client.instance_variable_get(:@buffer).size).to be <= config.buffer_size
  end

  def measure
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
end
