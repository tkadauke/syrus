require "rails_helper"

RSpec.describe ClaudeUsageProbe do
  let(:messages_url) { "https://api.anthropic.com/v1/messages" }

  it "probes /v1/messages with the stored OAuth token and classifies utilization" do
    user = Factories.user(claude_oauth_token: "sk-ant-oat01-abc")
    stub = stub_request(:post, messages_url)
      .with(
        headers: {
          "Authorization" => "Bearer sk-ant-oat01-abc",
          "anthropic-version" => "2023-06-01",
          "anthropic-beta" => "oauth-2025-04-20"
        },
        body: hash_including("model" => "claude-haiku-4-5-20251001", "max_tokens" => 1)
      )
      .to_return(
        status: 200,
        body: { id: "msg_1" }.to_json,
        headers: {
          "Content-Type" => "application/json",
          "anthropic-ratelimit-unified-5h-utilization" => "0.42",
          "anthropic-ratelimit-unified-5h-reset" => (Time.current + 90.minutes).to_i.to_s,
          "anthropic-ratelimit-unified-7d-utilization" => "0.10",
          "anthropic-ratelimit-unified-7d-reset" => (Time.current + 2.days).to_i.to_s,
          "anthropic-ratelimit-unified-representative-claim" => "five_hour"
        }
      )

    result = described_class.refresh_for(user: user, force: true)

    expect(stub).to have_been_requested
    expect(result.status).to eq("available")
    expect(result.snapshot).to include(
      "source" => "anthropic_messages_headers",
      "representative_claim" => "five_hour",
      "session_pct" => 42.0,
      "weekly_pct" => 10.0
    )
    expect(result.snapshot["session_reset_minutes"]).to be_within(1).of(90)
    evidence = ProviderAvailabilityEvidence.last
    expect(evidence).to have_attributes(user: user, provider: "claude", status: "available", source: "usage_probe")
  end

  it "classifies >= 85% utilization as warning and 100% as exhausted" do
    user = Factories.user(claude_oauth_token: "sk-ant-oat01-abc")
    stub_headers(utilization_5h: "0.85")

    result = described_class.refresh_for(user: user, force: true)
    expect(result.status).to eq("warning")

    stub_headers(utilization_5h: "1.0")
    result = described_class.refresh_for(user: user, force: true)
    expect(result.status).to eq("exhausted")
    expect(ProviderAvailabilityEvidence.last.status).to eq("exhausted")
  end

  it "does not probe when the user has no Claude OAuth token configured" do
    user = Factories.user

    result = described_class.refresh_for(user: user, force: true)

    expect(result.status).to eq("unsupported")
    expect(a_request(:post, messages_url)).not_to have_been_made
  end

  it "records auth failures distinctly from other HTTP failures" do
    user = Factories.user(claude_oauth_token: "sk-ant-oat01-bad")
    stub_request(:post, messages_url).to_return(status: 401, body: { error: { message: "invalid token" } }.to_json)

    result = described_class.refresh_for(user: user, force: true)

    expect(result.status).to eq("auth_error")
    expect(ProviderAvailabilityEvidence.last).to have_attributes(status: "auth_error", http_status: 401)
  end

  it "records probe_inconclusive rather than guessing when the API rejects the call for an unexpected reason" do
    user = Factories.user(claude_oauth_token: "sk-ant-oat01-abc")
    stub_request(:post, messages_url).to_return(status: 400, body: { error: { message: "unsupported beta header" } }.to_json)

    result = described_class.refresh_for(user: user, force: true)

    expect(result.status).to eq("probe_inconclusive")
  end

  it "records probe_inconclusive when the response succeeds but carries no rate-limit headers" do
    user = Factories.user(claude_oauth_token: "sk-ant-oat01-abc")
    stub_request(:post, messages_url).to_return(status: 200, body: { id: "msg_1" }.to_json, headers: { "Content-Type" => "application/json" })

    result = described_class.refresh_for(user: user, force: true)

    expect(result.status).to eq("probe_inconclusive")
  end

  it "does not re-probe within the staleness window unless forced" do
    user = Factories.user(claude_oauth_token: "sk-ant-oat01-abc")
    stub = stub_headers(utilization_5h: "0.1")

    described_class.refresh_for(user: user)
    described_class.refresh_for(user: user)

    expect(stub).to have_been_requested.times(1)
  end

  it "re-probes once the evidence is older than the staleness window" do
    user = Factories.user(claude_oauth_token: "sk-ant-oat01-abc")
    stub = stub_headers(utilization_5h: "0.1")

    described_class.refresh_for(user: user)
    ProviderAvailabilityEvidence.last.update!(observed_at: 11.minutes.ago)

    described_class.refresh_for(user: user)

    expect(stub).to have_been_requested.times(2)
  end

  def stub_headers(utilization_5h:, utilization_7d: "0.0")
    stub_request(:post, messages_url).to_return(
      status: 200,
      body: { id: "msg_1" }.to_json,
      headers: {
        "Content-Type" => "application/json",
        "anthropic-ratelimit-unified-5h-utilization" => utilization_5h,
        "anthropic-ratelimit-unified-5h-reset" => (Time.current + 1.hour).to_i.to_s,
        "anthropic-ratelimit-unified-7d-utilization" => utilization_7d,
        "anthropic-ratelimit-unified-7d-reset" => (Time.current + 1.day).to_i.to_s
      }
    )
  end
end
