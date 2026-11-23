require "rails_helper"
require Rails.root.join("plugins/connected_accounts/lib/connected_accounts/provider_test_kit").to_s
require_relative "../../support/telegram_bot_account"

RSpec.describe Telegram::Provider do
  let(:provider_class) { described_class }
  let(:provider_declaration) do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "telegram" }
    ConnectedAccounts::ProviderDeclaration.build(
      plugin_name: "telegram",
      attributes: Array(manifest.provides.fetch("connected_accounts:provider")).first
    )
  end
  let(:get_me) { "https://api.telegram.org/bottok-1234/getMe" }

  it_behaves_like "a connected accounts provider"

  it "declares token entry, a pinned API origin and its platform service identity" do
    expect(provider_declaration).to have_attributes(
      key: "telegram_bot", authorization_kind: "token", system_service_identities: [ "telegram.platform" ],
      api_origins: [ "https://api.telegram.org/" ]
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
    let(:identity_context) { ConnectedAccounts::Provider::IdentityContext.new(access_token: "tok-1234") }
    let(:validate_context) { ConnectedAccounts::Provider::ValidateContext.new(access_token: "tok-1234") }

    it "resolves the bot's @handle with getMe" do
      stub_request(:get, get_me).to_return(status: 200, body: JSON.generate("ok" => true, "result" => { "username" => "syrus_bot" }))

      expect(described_class.identity(identity_context)).to eq(label: "@syrus_bot")
      expect(described_class.validate(validate_context)).to eq(healthy: true, message: "ok")
    end

    it "reports an unhealthy account without echoing the token when Telegram rejects it" do
      stub_request(:get, get_me).to_return(status: 401, body: JSON.generate("ok" => false))

      result = described_class.validate(validate_context)

      expect(result).to eq(healthy: false, message: "Telegram rejected the bot token")
      expect(result.to_s).not_to include("tok-1234")
    end

    it "treats an outage as transient rather than unhealthy" do
      stub_request(:get, get_me).to_raise(Errno::ECONNREFUSED)

      expect { described_class.validate(validate_context) }.to raise_error(ConnectedAccounts::Provider::TransientError)
    end
  end
end
