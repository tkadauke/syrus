require "rails_helper"

RSpec.describe CodexUsageProbe do
  let(:usage_url) { "https://chatgpt.com/backend-api/wham/usage" }

  it "fetches ChatGPT Codex usage with the stored access token and normalizes remaining percentages" do
    user = Factories.user(codex_auth_mode: "chatgpt_login", codex_auth_json: auth_json(account_id: "account-123"))
    stub = stub_request(:get, usage_url)
      .with(headers: {
        "Authorization" => "Bearer access-token",
        "ChatGPT-Account-ID" => "account-123",
        "User-Agent" => "codex-cli"
      })
      .to_return(status: 200, body: usage_payload(primary: 42, secondary: 84).to_json,
                 headers: { "Content-Type" => "application/json" })

    result = described_class.refresh_for(user: user, force: true)

    expect(stub).to have_been_requested
    expect(result.status).to eq("warning")
    expect(result.snapshot).to include(
      "source" => "chatgpt_wham_usage",
      "plan_type" => "pro",
      "remaining_percent" => 16.0
    )
    expect(result.message).to eq("Codex usage has 16% remaining (5h 58%, weekly 16%).")
    expect(result.snapshot.dig("primary", "label")).to eq("5h")
    expect(result.snapshot.dig("primary", "remaining_percent")).to eq(58.0)
    expect(result.snapshot.dig("secondary", "label")).to eq("weekly")
    expect(result.snapshot.dig("secondary", "remaining_percent")).to eq(16.0)
    expect(user.reload.codex_usage_status).to eq("warning")
  end

  it "marks rate-limit reached responses as exhausted" do
    user = Factories.user(codex_auth_mode: "chatgpt_login", codex_auth_json: auth_json)
    stub_request(:get, usage_url).to_return(
      status: 200,
      body: usage_payload(primary: 100, secondary: 10).merge(
        "rate_limit_reached_type" => { "kind" => "rate_limit_reached" }
      ).to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = described_class.refresh_for(user: user, force: true)

    expect(result.status).to eq("exhausted")
    expect(user.reload.codex_usage_snapshot["rate_limit_reached_type"]).to eq("rate_limit_reached")
  end

  it "does not claim subscription visibility for API-key mode" do
    user = Factories.user(codex_auth_mode: "api_key", codex_api_key: "sk-test")

    result = described_class.refresh_for(user: user, force: true)

    expect(result.status).to eq("unsupported")
    expect(a_request(:get, usage_url)).not_to have_been_made
  end

  it "records 429 usage responses as exhausted" do
    user = Factories.user(codex_auth_mode: "chatgpt_login", codex_auth_json: auth_json)
    stub_request(:get, usage_url).to_return(status: 429, body: { error: "usage limit reached" }.to_json)

    result = described_class.refresh_for(user: user, force: true)

    expect(result.status).to eq("exhausted")
    expect(user.reload.codex_usage_snapshot).to include("http_status" => 429)
  end

  it "does not treat a zero add-on credit balance as exhausted while rate-limit capacity remains" do
    user = Factories.user(codex_auth_mode: "chatgpt_login", codex_auth_json: auth_json)
    stub_request(:get, usage_url).to_return(
      status: 200,
      body: usage_payload(primary: 2, secondary: nil).merge(
        "credits" => { "has_credits" => false, "unlimited" => false, "balance" => "0" }
      ).to_json,
      headers: { "Content-Type" => "application/json" }
    )

    result = described_class.refresh_for(user: user, force: true)

    expect(result.status).to eq("ok")
    expect(result.snapshot["remaining_percent"]).to eq(98.0)
  end

  def usage_payload(primary:, secondary:)
    secondary_window =
      if secondary.nil?
        nil
      else
        {
          "used_percent" => secondary,
          "limit_window_seconds" => 604_800,
          "reset_after_seconds" => 3_600,
          "reset_at" => 1_785_401_400
        }
      end
    {
      "plan_type" => "pro",
      "rate_limit" => {
        "primary_window" => {
          "used_percent" => primary,
          "limit_window_seconds" => 18_000,
          "reset_after_seconds" => 120,
          "reset_at" => 1_785_398_400
        },
        "secondary_window" => secondary_window
      },
      "credits" => {
        "has_credits" => true,
        "unlimited" => false,
        "balance" => "9.99"
      },
      "spend_control" => {
        "reached" => false,
        "individual_limit" => {
          "limit" => "25000",
          "used" => "8000",
          "remaining_percent" => 68,
          "reset_at" => 1_785_401_400
        }
      },
      "additional_rate_limits" => []
    }
  end

  def auth_json(account_id: nil)
    JSON.generate(
      "auth_mode" => "chatgpt",
      "tokens" => {
        "id_token" => jwt(account_id: account_id),
        "access_token" => "access-token",
        "refresh_token" => "refresh-token"
      }
    )
  end

  def jwt(account_id: nil)
    claims = {
      "https://api.openai.com/auth" => {
        "chatgpt_account_id" => account_id,
        "chatgpt_account_is_fedramp" => false
      }.compact
    }
    [
      Base64.urlsafe_encode64({ "alg" => "none" }.to_json, padding: false),
      Base64.urlsafe_encode64(claims.to_json, padding: false),
      "signature"
    ].join(".")
  end
end
