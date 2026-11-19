require "rails_helper"

RSpec.describe "Connected accounts OAuth", type: :request do
  let(:user) { Factories.user }
  let(:declaration) do
    instance_double(ConnectedAccounts::ProviderDeclaration, key: "generic_oauth2",
      callback_route: "/api/v1/app/connected_accounts/callback/generic_oauth2", connect_scope_keys: %w[profile email calendar.write],
      read_only_scope_keys: %w[profile email])
  end

  before do
    PluginRecord.find_by!(name: "connected_accounts").update!(enabled: true)
    sign_in_as(user)
    allow(ConnectedAccounts::ProviderRegistry).to receive(:fetch).with("generic_oauth2").and_return(declaration)
  end

  it "starts authorization with configured scopes, PKCE state, and the read-only ceiling" do
    allow(declaration).to receive(:call).with("authorization", anything).and_return(authorize_url: "https://oauth.example/authorize")

    get "/api/v1/app/connected_accounts/connect/generic_oauth2", params: { scopes: "profile,email,calendar.write", read_only: true }

    expect(response).to redirect_to("https://oauth.example/authorize")
    expect(declaration).to have_received(:call).with("authorization", satisfy { |context|
      context.state.present? && context.code_verifier.present? && context.requested_scopes == %w[profile email] && context.read_only
    })
  end

  it "completes a successful callback" do
    allow(ConnectedAccounts::OauthBroker).to receive(:complete!).and_return(instance_double(ConnectedAccounts::Account))

    get "/api/v1/app/connected_accounts/callback/generic_oauth2", params: { state: "state", code: "code" }

    expect(response).to redirect_to("/admin/connected_accounts")
    expect(ConnectedAccounts::OauthBroker).to have_received(:complete!).with(hash_including(provider: "generic_oauth2", state: "state", code: "code", user: user))
  end

  it "handles provider denial without attempting an exchange" do
    allow(ConnectedAccounts::OauthBroker).to receive(:complete!)
    allow(ConnectedAccounts::OauthState).to receive(:consume!)

    get "/api/v1/app/connected_accounts/callback/generic_oauth2", params: { error: "access_denied", state: "denied-state" }

    expect(response).to redirect_to("/admin/connected_accounts")
    expect(ConnectedAccounts::OauthState).to have_received(:consume!).with(hash_including(token: "denied-state", user: user, provider: "generic_oauth2"))
    expect(ConnectedAccounts::OauthBroker).not_to have_received(:complete!)
  end

  it "handles mismatched, expired, or replayed state as invalid" do
    allow(ConnectedAccounts::OauthBroker).to receive(:complete!).and_raise(ActiveRecord::RecordNotFound)

    get "/api/v1/app/connected_accounts/callback/generic_oauth2", params: { state: "invalid", code: "code" }

    expect(response).to redirect_to("/admin/connected_accounts")
    expect(flash[:alert]).to eq(I18n.t("connected_accounts.oauth.invalid_state"))
  end
end
