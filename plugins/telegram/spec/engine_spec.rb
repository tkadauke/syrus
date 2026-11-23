require "rails_helper"

RSpec.describe SyrusTelegram::Engine do
  let(:record) { PluginRecord.find_by!(name: "telegram") }

  it "registers the Telegram platform_delivery plugin disabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "telegram" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(Syrus::PluginRegistry.providers_for(:platform_delivery)).not_to include(Telegram::PlatformAdapter)
  end

  it "exposes the Telegram platform_delivery provider when enabled" do
    record.update!(enabled: true)

    expect(Syrus::PluginRegistry.providers_for(:platform_delivery)).to include(Telegram::PlatformAdapter)
    expect(PlatformDelivery::Registry.for("telegram")).to be_a(Telegram::PlatformAdapter)
    expect(Telegram::PlatformAdapter.connector_job_class).to eq(Telegram::PollUpdatesJob)
  end

  it "makes telegram a valid PlatformIdentity platform once enabled" do
    expect(PlatformIdentity.available_platforms).not_to include("telegram")

    record.update!(enabled: true)

    expect(PlatformIdentity.available_platforms).to include("telegram")
  end

  it "runs its poller on a consumed plugin queue" do
    expect(Telegram::PollUpdatesJob.new.queue_name).to eq("plugin_telegram")
  end
end
