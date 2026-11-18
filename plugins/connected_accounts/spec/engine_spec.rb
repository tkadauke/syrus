require "rails_helper"

RSpec.describe "Connected Accounts plugin" do
  it "hosts its account-provider contract" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "connected_accounts" }

    expect(manifest.hosted_extension_points).to include("connected_accounts:provider")
  end
end
