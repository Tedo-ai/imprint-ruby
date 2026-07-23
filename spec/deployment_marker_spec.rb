# frozen_string_literal: true

require "spec_helper"
require "imprint"
require "webmock/rspec"

RSpec.describe "Imprint.deployment_marker" do
  let(:deployments_url) { "https://ingest.example.com/v1/deployments" }

  before do
    Imprint.configure do |c|
      c.api_key = "test-key"
      c.ingest_url = "https://ingest.example.com/v1/spans"
      c.service_name = "spec-service"
      c.enabled = true
    end
    # Isolate env-based auto-detection between examples.
    %w[IMPRINT_REVISION APP_REVISION CI_ACTOR GITHUB_ACTOR USER
       GITHUB_REF_NAME GITHUB_SHA].each { |k| ENV.delete(k) }
  end

  after do
    Imprint.configuration = nil
    Imprint.instance_variable_set(:@client, nil)
  end

  describe "auto-detection from ENV" do
    before do
      ENV["APP_REVISION"] = "abc123"
      ENV["GITHUB_ACTOR"] = "octocat"
      ENV["GITHUB_REF_NAME"] = "main"
      ENV["GITHUB_SHA"] = "abc123def456"
    end

    it "derives revision, deployed_by, branch and commit_ref from the environment" do
      stub = stub_request(:post, deployments_url)
             .with(
               headers: { "Authorization" => "Bearer test-key" },
               body: {
                 "revision" => "abc123",
                 "deployed_by" => "octocat",
                 "service" => "spec-service",
                 "branch" => "main",
                 "commit_ref" => "abc123def456"
               }
             )
             .to_return(status: 201, body: '{"id":"dep_1"}')

      result = Imprint.deployment_marker

      expect(stub).to have_been_requested
      expect(result).to eq("id" => "dep_1")
    end

    it "prefers IMPRINT_REVISION over APP_REVISION" do
      ENV["IMPRINT_REVISION"] = "override-sha"

      stub = stub_request(:post, deployments_url)
             .with(body: hash_including("revision" => "override-sha"))
             .to_return(status: 200, body: "{}")

      Imprint.deployment_marker
      expect(stub).to have_been_requested
    end

    it "includes an explicit changelog_url when provided" do
      stub = stub_request(:post, deployments_url)
             .with(body: hash_including("changelog_url" => "https://example.com/notes"))
             .to_return(status: 200, body: "{}")

      Imprint.deployment_marker(changelog_url: "https://example.com/notes")
      expect(stub).to have_been_requested
    end

    it "does not send project or environment (server derives them from the API key)" do
      captured = nil
      stub_request(:post, deployments_url)
        .with { |req| captured = JSON.parse(req.body); true }
        .to_return(status: 200, body: "{}")

      Imprint.deployment_marker

      expect(captured).not_to have_key("project")
      expect(captured).not_to have_key("environment")
    end
  end

  describe "validation" do
    it "raises ArgumentError when revision cannot be resolved" do
      allow(Imprint).to receive(:default_revision).and_return(nil)
      ENV["GITHUB_ACTOR"] = "octocat"

      expect { Imprint.deployment_marker }
        .to raise_error(ArgumentError, /revision/)
    end

    it "raises ArgumentError when deployed_by cannot be resolved" do
      ENV["APP_REVISION"] = "abc123"

      expect { Imprint.deployment_marker }
        .to raise_error(ArgumentError, /deployed_by/)
    end
  end

  describe "error surfacing" do
    before do
      ENV["APP_REVISION"] = "abc123"
      ENV["GITHUB_ACTOR"] = "octocat"
    end

    it "raises Imprint::Error on a non-2xx response instead of swallowing it" do
      stub_request(:post, deployments_url)
        .to_return(status: 500, body: "boom")

      expect { Imprint.deployment_marker }
        .to raise_error(Imprint::Error, /deployment marker failed: 500/)
    end
  end
end
