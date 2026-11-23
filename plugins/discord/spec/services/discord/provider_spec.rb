require "rails_helper"
require Rails.root.join("plugins/connected_accounts/lib/connected_accounts/provider_test_kit").to_s
require_relative "../../support/discord_bot_account"

RSpec.describe Discord::Provider do
  let(:provider_class) { described_class }
  let(:provider_declaration) do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "discord" }
    ConnectedAccounts::ProviderDeclaration.build(
      plugin_name: "discord",
      attributes: Array(manifest.provides.fetch("connected_accounts:provider")).first
    )
  end
  let(:users_me) { "https://discord.com/api/v10/users/@me" }

  it_behaves_like "a connected accounts provider"

  it "declares token entry, a pinned API origin and its platform service identity" do
    expect(provider_declaration).to have_attributes(
      key: "discord_bot", authorization_kind: "token", system_service_identities: [ "discord.platform" ],
      api_origins: [ "https://discord.com/api/v10/" ]
    )
  end

  it "describes token entry as its authorization and rejects a code exchange" do
    expect(described_class.authorization(nil)).to include(authorization_kind: "token")
    expect { described_class.exchange_code(nil) }.to raise_error(ConnectedAccounts::Provider::PermanentError)
  end

  it "has a no-op revoke and returns tokens unchanged on refresh" do
    tokens = { "access_token" => "tok" }
    expect(described_class.revoke(ConnectedAccounts::Provider::RevokeContext.new(tokens: tokens))).to eq(revoked: true)
    expect(described_class.refresh(ConnectedAccounts::Provider::RefreshContext.new(tokens: tokens))).to eq(tokens)
  end

  describe ".identity / .validate" do
    let(:context) { ConnectedAccounts::Provider::IdentityContext.new(access_token: "tok-1234") }

    it "resolves the bot's username with a harmless authenticated call" do
      stub_request(:get, users_me).with(headers: { "Authorization" => "Bot tok-1234" })
        .to_return(status: 200, body: JSON.generate("id" => "1", "username" => "SyrusBot"))

      expect(described_class.identity(context)).to eq(label: "SyrusBot")
      expect(described_class.validate(ConnectedAccounts::Provider::ValidateContext.new(access_token: "tok-1234")))
        .to eq(healthy: true, message: "ok")
    end

    it "reports an unhealthy account without echoing the token when Discord rejects it" do
      stub_request(:get, users_me).to_return(status: 401, body: "{}")

      result = described_class.validate(ConnectedAccounts::Provider::ValidateContext.new(access_token: "tok-1234"))

      expect(result).to eq(healthy: false, message: "Discord rejected the bot token")
      expect(result.to_s).not_to include("tok-1234")
    end

    it "treats an outage as transient rather than unhealthy" do
      stub_request(:get, users_me).to_return(status: 503, body: "")

      expect { described_class.validate(ConnectedAccounts::Provider::ValidateContext.new(access_token: "tok-1234")) }
        .to raise_error(ConnectedAccounts::Provider::TransientError)
    end
  end
end
