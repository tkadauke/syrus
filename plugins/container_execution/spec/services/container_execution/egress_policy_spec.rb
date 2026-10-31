require "rails_helper"

RSpec.describe ContainerExecution::EgressPolicy::Base do
  PROVIDER_ENDPOINTS = {
    "codex" => "api.openai.com",
    "claude" => "api.anthropic.com",
    "muse" => "api.muse.dev",
    "agy" => "generativelanguage.googleapis.com"
  }.freeze

  PROVIDER_ENDPOINTS.each do |provider, endpoint|
    it "allows only #{provider} model traffic and keeps MCP on its local transport" do
      policy = described_class.for(provider)

      expect(policy.allows_destination?("https://#{endpoint}/v1/models?secret=redacted")).to be(true)
      expect(policy.allows_destination?("https://example.com/")).to be(false)
      expect(policy.allows_destination?("http://169.254.169.254/latest/meta-data")).to be(false)
      expect(policy.allows_destination?("https://10.96.0.1/api")).to be(false)
      expect(policy.allows_destination?("postgres://192.168.1.20:5432/database")).to be(false)
      expect(policy.endpoint_hosts).not_to include("github.com", "api.github.com")
    end
  end

  it "rejects proxy configuration containing credentials or request data" do
    previous = ENV.to_h
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_NETWORK"] = "isolated"
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_DNS"] = "192.0.2.53"
    ENV["SYRUS_CONTAINER_EXECUTION_CODEX_PROXY"] = "http://user:secret@proxy.test:3128/?token=secret"

    expect(described_class.for("codex")).not_to be_configured
  ensure
    ENV.replace(previous)
  end

  it "rejects Docker's shared and unconfined network modes" do
    previous = ENV.to_h
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_DNS"] = "192.0.2.53"
    ENV["SYRUS_CONTAINER_EXECUTION_CODEX_PROXY"] = "http://proxy.test:3128"

    %w[bridge default host none].each do |network|
      ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_NETWORK"] = network
      expect(described_class.for("codex")).not_to be_configured
    end
  ensure
    ENV.replace(previous)
  end
end
