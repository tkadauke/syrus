require "rails_helper"

RSpec.describe "API: provider accounts", type: :request do
  let(:user) { Factories.user }

  def body = JSON.parse(response.body)

  before { sign_in_as(user) }

  it "creates multiple opaque Claude accounts without returning their secrets" do
    4.times do |index|
      post "/api/v1/app/provider_accounts", params: {
        provider_key: "claude",
        label: index == 1 ? "Work" : "",
        credentials: { claude_oauth_token: "secret-#{index}" }
      }
      expect(response).to have_http_status(:created), response.body
    end

    get "/api/v1/app/provider_accounts"

    expect(body["provider_accounts"].pluck("display_label")).to eq([ "Claude Code 1", "Work", "Claude Code 3", "Claude Code 4" ])
    expect(body.to_json).not_to include("secret-")
    expect(body["provider_accounts"].pluck("id")).to all(match(/\A[0-9a-f-]{36}\z/))
    expect(user.provider_accounts.in_position_order.map { |account| account.credential(:claude_oauth_token) }).to eq(4.times.map { |index| "secret-#{index}" })
  end

  it "normalizes blank labels and rejects duplicate labels within a provider" do
    account = user.provider_accounts.create!(provider_key: "claude", authentication_kind: "oauth_token", credential_payload: { "claude_oauth_token" => "one" }, label: "Work", position: 0)

    patch "/api/v1/app/provider_accounts/#{account.public_id}", params: { label: "" }
    expect(response).to have_http_status(:ok)
    expect(account.reload.label).to be_nil

    user.provider_accounts.create!(provider_key: "claude", authentication_kind: "oauth_token", credential_payload: { "claude_oauth_token" => "two" }, label: "Work", position: 1)
    patch "/api/v1/app/provider_accounts/#{account.public_id}", params: { label: "work" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(body.dig("error", "code")).to eq("validation_failed")
  end

  it "disables an account while preserving it and updates advanced routing controls" do
    account = user.provider_accounts.create!(provider_key: "claude", authentication_kind: "oauth_token", credential_payload: { "claude_oauth_token" => "one" }, position: 0)

    patch "/api/v1/app/provider_accounts/#{account.public_id}", params: { enabled: false, weight: 2.5, proactive_pause_threshold: 7 }

    expect(response).to have_http_status(:ok)
    expect(account.reload).to have_attributes(enabled: false, weight: 2.5, proactive_pause_threshold: 7)
    expect(body.dig("provider_account", "effective_proactive_pause_threshold")).to eq(7.0)
  end

  it "guards removal while an active Workflow references the account" do
    user.update!(claude_oauth_token: "one")
    account = user.default_provider_account("claude")
    workflow = Factories.job(repository: Factories.repository(user: user), agent_provider: "claude").latest_workflow
    workflow.update!(provider_account: account)

    delete "/api/v1/app/provider_accounts/#{account.public_id}"

    expect(response).to have_http_status(:conflict)
    expect(body.dig("error", "code")).to eq("provider_account_in_use")
    expect(account.reload).to be_present
  end
end
