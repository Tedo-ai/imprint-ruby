# frozen_string_literal: true

require "spec_helper"
require "active_support/notifications"
require "imprint"
require "imprint/rails/subscriber"

RSpec.describe Imprint::Rails::Subscriber do
  let(:queued_spans) { [] }
  let(:client) { instance_double(Imprint::Client, enabled?: true) }
  let(:parent_span) do
    Imprint::Span.new(
      trace_id: "trace123",
      span_id: "parent123",
      namespace: "spec-service",
      name: "GET /items/123",
      kind: "server",
      client: nil
    )
  end

  before do
    Imprint.configure do |config|
      config.service_name = "spec-service"
      config.enabled = false
    end

    allow(Imprint).to receive(:client).and_return(client)
    allow(client).to receive(:queue_span) { |span| queued_spans << span }
    Imprint::Context.current_span = parent_span
  end

  after do
    Imprint::Context.clear!
  end

  it "creates cache fetch-hit spans with sanitized key prefixes" do
    described_class.send(
      :handle_cache_event,
      notification_args(
        "cache_fetch_hit.active_support",
        key: "views/users/123/20260418/profile",
        super_operation: :fetch
      )
    )

    expect(queued_spans.length).to eq(1)
    span = queued_spans.first

    expect(span.name).to eq("cache.fetch")
    expect(span.attributes).to include(
      "cache.hit" => "true",
      "cache.operation" => "fetch_hit",
      "cache.key_prefix" => "views/users/*",
      "cache.super_operation" => "fetch"
    )
  end

  it "creates cache miss compute spans for generated values" do
    described_class.send(
      :handle_cache_event,
      notification_args(
        "cache_generate.active_support",
        key: "bid_cache:lot:987654321:render"
      )
    )

    expect(queued_spans.length).to eq(1)
    span = queued_spans.first

    expect(span.name).to eq("cache_miss_compute")
    expect(span.attributes).to include(
      "cache.hit" => "false",
      "cache.operation" => "generate",
      "cache.key_prefix" => "bid_cache:lot:*"
    )
  end

  it "creates partial render spans from Action View notifications" do
    described_class.send(
      :handle_view_event,
      notification_args(
        "render_partial.action_view",
        identifier: "/app/views/lots/_row.html.erb",
        virtual_path: "lots/_row"
      )
    )

    expect(queued_spans.length).to eq(1)
    span = queued_spans.first

    expect(span.name).to eq("render partial lots/_row")
    expect(span.attributes).to include(
      "template.identifier" => "/app/views/lots/_row.html.erb",
      "template.virtual_path" => "lots/_row"
    )
  end

  it "creates collection render spans with count metadata" do
    described_class.send(
      :handle_view_event,
      notification_args(
        "render_collection.action_view",
        identifier: "/app/views/lots/_row.html.erb",
        virtual_path: "lots/_row",
        count: 20
      )
    )

    expect(queued_spans.length).to eq(1)
    span = queued_spans.first

    expect(span.name).to eq("render collection lots/_row")
    expect(span.attributes["template.count"]).to eq("20")
  end

  it "adds allocation counts to the controller root span" do
    described_class.send(
      :handle_controller_event,
      notification_args(
        "process_action.action_controller",
        method: "GET",
        path: "/lots/123",
        controller: "LotsController",
        action: "show",
        allocations: 12_345
      )
    )

    expect(parent_span.attributes).to include(
      "controller" => "LotsController",
      "action" => "show",
      "process.ruby.objects.allocated" => "12345"
    )
  end

  it "creates mailer spans from Action Mailer notifications" do
    described_class.send(
      :handle_mailer_event,
      notification_args(
        "deliver.action_mailer",
        mailer: "UserMailer",
        action: "welcome_email",
        message_id: "msg-123",
        subject: "Welcome",
        to: ["rene@example.com"]
      )
    )

    expect(queued_spans.length).to eq(1)
    span = queued_spans.first

    expect(span.name).to eq("mailer.deliver")
    expect(span.attributes).to include(
      "mailer.class" => "UserMailer",
      "mailer.action" => "welcome_email",
      "email.message_id" => "msg-123",
      "email.subject" => "Welcome",
      "mailer.to_count" => "1"
    )
  end

  def notification_args(name, payload = {}, duration_ms: 12.5, **payload_kwargs)
    start_time = Time.now
    finish_time = start_time + (duration_ms / 1000.0)
    merged_payload = payload.merge(payload_kwargs)
    [name, start_time, finish_time, SecureRandom.hex(6), merged_payload]
  end
end
