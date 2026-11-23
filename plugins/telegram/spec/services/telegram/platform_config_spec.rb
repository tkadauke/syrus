require "rails_helper"

RSpec.describe Telegram::PlatformConfig do
  it "is configured only when a bot handle is present" do
    AppSetting.current.update!(telegram_bot_handle: nil)
    expect(described_class.new.configured?).to be false

    AppSetting.current.update!(telegram_bot_handle: "MyBot")
    expect(described_class.new.configured?).to be true
  end

  it "tells the user to send /start <token> to the bot" do
    AppSetting.current.update!(telegram_bot_handle: "MyBot")

    expect(described_class.new.instructions("tok")).to eq(
      text: "Send /start tok to @MyBot on Telegram", bot_handle: "MyBot"
    )
  end
end
