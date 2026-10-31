require "rails_helper"

RSpec.describe ContainerExecution::EgressPolicy::Base do
  provider_endpoints = {
    "codex" => "api.openai.com",
    "claude" => "api.anthropic.com",
    "muse" => "api.muse.dev",
    "agy" => "generativelanguage.googleapis.com"
  }.freeze

  provider_endpoints.each do |provider, endpoint|
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

  it "records only the normalized host and port for denied destinations" do
    policy = described_class.for("codex")

    expect(Rails.logger).to receive(:info).with(
      event: "coworker_egress_denied",
      profile: "codex",
      destination_host: "example.com",
      destination_port: 8443
    )

    expect(policy.allows_destination?("https://user:secret@example.com:8443/private?token=secret#response-data")).to be(false)
  end

  it "sets both proxy environment spellings and clears both bypass lists" do
    allow(ContainerExecution::Configuration).to receive(:coworker_proxy_url)
      .with("codex").and_return("http://proxy.test:3128")

    expect(described_class.for("codex").proxy_env).to include(
      "HTTP_PROXY" => "http://proxy.test:3128", "http_proxy" => "http://proxy.test:3128",
      "HTTPS_PROXY" => "http://proxy.test:3128", "https_proxy" => "http://proxy.test:3128",
      "ALL_PROXY" => "http://proxy.test:3128", "all_proxy" => "http://proxy.test:3128",
      "NO_PROXY" => "", "no_proxy" => ""
    )
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

  it "rejects a proxy endpoint on a blocked network" do
    previous = ENV.to_h
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_NETWORK"] = "isolated"
    ENV["SYRUS_CONTAINER_EXECUTION_COWORKER_DNS"] = "192.0.2.53"
    ENV["SYRUS_CONTAINER_EXECUTION_CODEX_PROXY"] = "http://169.254.169.254:3128"

    expect(described_class.for("codex")).not_to be_configured
  ensure
    ENV.replace(previous)
  end

  it "denies IPv4-mapped IPv6 metadata addresses" do
    expect(Rails.logger).to receive(:info).with(hash_including(
      event: "coworker_egress_denied",
      destination_host: "::ffff:169.254.169.254"
    ))

    expect(described_class.for("codex").allows_destination?("http://[::ffff:169.254.169.254]/latest/meta-data")).to be(false)
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
