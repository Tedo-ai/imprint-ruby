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

  it "drops on overflow instead of growing unbounded, and counts the drops" do
    # Keep the worker from draining so the queue actually fills.
    allow(client).to receive(:flush_sync)
    allow(client).to receive(:flush_logs_sync)
    config.buffer_size = 10
    (config.buffer_size + 50).times { client.queue_span(make_span) }
    expect(client.instance_variable_get(:@span_queue).size).to be <= config.buffer_size
    expect(client.dropped_spans_count).to be >= 50
  end

  it "restarts the worker after a fork so forked (Puma) workers still export" do
    client.queue_span(make_span) # worker running in this process
    original = client.instance_variable_get(:@worker_thread)

    # Simulate being inside a fork: a different pid than the worker was started under.
    client.instance_variable_set(:@worker_pid, -1)
    exported = Queue.new
    allow(client).to receive(:send_batch) { exported << Thread.current }

    config.batch_size.times { client.queue_span(make_span) }
    Timeout.timeout(5) { exported.pop } # export resumes → worker was re-started

    expect(client.instance_variable_get(:@worker_thread)).not_to equal(original)
    expect(client.instance_variable_get(:@worker_pid)).to eq(Process.pid)
  end

  it "chunks an oversized drain into batch_size-sized POSTs" do
    config.batch_size = 5
    q = client.instance_variable_get(:@span_queue)
    12.times { q << make_span } # pushed directly: no wake, worker stays asleep
    sizes = []
    allow(client).to receive(:send_batch) { |spans| sizes << spans.size }
    client.send(:flush_sync)
    expect(sizes).to eq([5, 5, 2])
  end

  def measure
    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
  end
end
