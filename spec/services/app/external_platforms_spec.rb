require "rails_helper"

RSpec.describe App::ExternalPlatforms do
  describe ".names" do
    it "matches PlatformIdentity platform values" do
      expect(described_class.names).to eq(PlatformIdentity::PLATFORMS)
    end
  end

  describe ".fetch" do
    it "returns platform behavior objects by key" do
      expect(described_class.fetch("telegram")).to eq(App::ExternalPlatforms::Telegram)
    end

    it "raises for unknown platforms" do
      expect { described_class.fetch("discord") }.to raise_error(KeyError)
    end
  end

  describe App::ExternalPlatforms::Telegram do
    it "is configured only when bot token and handle are set" do
      AppSetting.current.update!(telegram_bot_token: "token", telegram_bot_handle: nil)
      expect(described_class).not_to be_configured

      AppSetting.current.update!(telegram_bot_handle: "MySyrusBot")
      expect(described_class).to be_configured
    end

    it "builds linking instructions from the configured bot handle" do
      AppSetting.current.update!(telegram_bot_handle: "MySyrusBot")

      expect(described_class.linking_instructions("abc")).to eq(
        text: "Send /start abc to @MySyrusBot on Telegram",
        bot_handle: "MySyrusBot"
      )
    end
  end
end
