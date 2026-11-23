require "rails_helper"
require_relative "support/telegram_bot_account"

RSpec.describe SyrusTelegram::Engine do
  it "registers the Telegram platform_delivery plugin disabled by default" do
    manifest = Syrus::PluginRegistry.all_plugins.find { |plugin| plugin.name == "telegram" }

    expect(manifest).to be_present
    expect(manifest.default_enabled?).to be(false)
    expect(Syrus::PluginRegistry.providers_for(:platform_delivery)).not_to include(Telegram::PlatformAdapter)
  end

  it "exposes the Telegram platform_delivery provider and platform when enabled" do
    enable_telegram_plugin!

    expect(Syrus::PluginRegistry.providers_for(:platform_delivery)).to include(Telegram::PlatformAdapter)
    expect(PlatformIdentity.available_platforms).to include("telegram")
    expect(PlatformDelivery::Registry.for("telegram")).to be_a(Telegram::PlatformAdapter)
  end

  it "is not a valid platform while disabled" do
    expect(PlatformIdentity.available_platforms).not_to include("telegram")
  end

  it "resolves its platform config once enabled" do
    enable_telegram_plugin!

    expect(PlatformIdentity::PlatformConfig::Base.for("telegram")).to be_a(Telegram::PlatformConfig)
  end

  it "keeps its connector job on a consumed plugin queue" do
    expect(Telegram::PollUpdatesJob.new.queue_name).to eq("plugin_telegram")
  end
end
