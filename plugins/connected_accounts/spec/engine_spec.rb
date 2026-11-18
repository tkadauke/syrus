require "rails_helper"

RSpec.describe ConnectedAccounts::Engine do
  let(:manifest) do
    Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "connected_accounts" }
  end

  it "is experimental, default-disabled, and depends only on Credential Store" do
    expect(manifest).to be_present
    expect(manifest.experimental?).to be(true)
    expect(manifest.default_enabled?).to be(false)
    expect(manifest.depends_on).to eq([ "credential_store" ])
  end

  it "declares its OAuth credential type with AccountClient as the typed consumer" do
    declaration = manifest.credential_types.sole

    expect(declaration).to include("name" => "connected_accounts.oauth")
    expect(declaration.fetch("typed_consumer")).to include(
      "name" => ConnectedAccounts::AccountClient::TOOL_NAME
    )
  end
end
