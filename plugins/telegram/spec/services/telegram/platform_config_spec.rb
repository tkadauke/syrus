require "rails_helper"

RSpec.describe Telegram::PlatformConfig do
  describe "#configured?" do
    it "is false until a bot handle is set" do
      AppSetting.current.update!(telegram_bot_handle: nil)

      expect(described_class.new.configured?).to be(false)
    end

    it "is true once a bot handle is set" do
      AppSetting.current.update!(telegram_bot_handle: "syrus_bot")

      expect(described_class.new.configured?).to be(true)
    end
  end

  describe "#instructions" do
    it "tells the user to send /start with the token to the bot" do
      AppSetting.current.update!(telegram_bot_handle: "syrus_bot")

      expect(described_class.new.instructions("tok")).to eq(
        text: "Send /start tok to @syrus_bot on Telegram", bot_handle: "syrus_bot"
      )
    end
  end

  it "is resolved by PlatformIdentity::PlatformConfig::Base.for once the plugin is enabled" do
    PluginRecord.find_by!(name: "telegram").update!(enabled: true)

    expect(PlatformIdentity::PlatformConfig::Base.for("telegram")).to be_a(described_class)
  end
end
