require "rails_helper"

RSpec.describe SyrusDiscord::Engine do
  it "registers the Discord platform_delivery plugin disabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "discord" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(Syrus::PluginRegistry.providers_for(:platform_delivery)).not_to include(Discord::PlatformAdapter)
  end

  it "exposes the Discord platform_delivery provider when enabled" do
    PluginRecord.find_by!(name: "discord").update!(enabled: true)

    expect(Syrus::PluginRegistry.providers_for(:platform_delivery)).to include(Discord::PlatformAdapter)
  end

  it "makes discord a valid PlatformIdentity platform once enabled" do
    PluginRecord.find_by!(name: "discord").update!(enabled: true)

    expect(PlatformIdentity.available_platforms).to include("discord")
  end
end
