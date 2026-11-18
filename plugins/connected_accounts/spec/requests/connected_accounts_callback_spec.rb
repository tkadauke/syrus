require "rails_helper"

RSpec.describe "connected account callback", type: :request do
  let(:user) { Factories.user }

  before do
    PluginRecord.find_or_initialize_by(name: "credential_store").update!(enabled: true)
    PluginRecord.find_or_initialize_by(name: "connected_accounts").update!(enabled: true)
    sign_in_as(user)
  end

  it "uses a fixed safe error redirect and never echoes callback parameters or secrets" do
    get "/api/v1/app/connected_accounts/callback/fake", params: {
      state: "attacker-state-secret", code: "authorization-code-secret"
    }

    expect(response).to redirect_to("/settings/connected_accounts?oauth_error=invalid_state")
    expect(response.body).not_to include("attacker-state-secret", "authorization-code-secret")
  end

  it "logs only the error class when callback processing fails" do
    allow(ConnectedAccounts::OauthFlow).to receive(:complete!)
      .and_raise(RuntimeError, "provider exposed access-secret and refresh-secret")
    expect(Rails.logger).to receive(:warn).with("Connected account OAuth callback failed: RuntimeError")

    get "/api/v1/app/connected_accounts/callback/fake", params: {
      state: "attacker-state-secret", code: "authorization-code-secret"
    }

    expect(response).to redirect_to("/settings/connected_accounts?oauth_error=connection_failed")
  end
end
