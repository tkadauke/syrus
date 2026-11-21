require "rails_helper"
require Rails.root.join("plugins/connected_accounts/lib/connected_accounts/provider_test_kit").to_s

RSpec.describe "Connected Accounts provider contract" do
  let(:provider_class) { ConnectedAccounts::FakeProvider }
  let(:provider_declaration) do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "connected_accounts" }
    ConnectedAccounts::ProviderDeclaration.build(
      plugin_name: manifest.name,
      attributes: Array(manifest.provides.fetch("connected_accounts:provider")).first
    )
  end

  it_behaves_like "a connected accounts provider"

  it "rejects the broken-provider fixture used to prove the contract kit" do
    broken = Class.new do
      def self.authorization(_first, _second) = nil
    end
    stub_const("ConnectedAccountsContractBrokenProvider", broken)
    declaration = instance_double(
      ConnectedAccounts::ProviderDeclaration,
      validate!: true,
      capabilities: ConnectedAccounts::Provider::REQUIRED_CAPABILITIES
    )

    expect {
      ConnectedAccounts::ProviderTestKit.validate!(provider_class: broken, declaration: declaration)
    }.to raise_error(ArgumentError, /must accept one context object/)
  end
end
