require "rails_helper"
require_relative "../../support/telegram_bot_account"

RSpec.describe Telegram::PlatformConfig do
  before { enable_telegram_plugin! }

  it "is configured only when the bot account is connected" do
    expect(described_class.new.configured?).to be false

    connect_telegram_bot!
    expect(described_class.new.configured?).to be true

    ConnectedAccounts::Account.update_all(status: "revoked")
    expect(described_class.new.configured?).to be false
  end

  it "tells the user to send /start <token> to the bot using the handle Telegram reports" do
    connect_telegram_bot!
    allow(Telegram::Client).to receive(:new).and_return(instance_double(Telegram::Client, get_me: { "username" => "MyBot" }))

    expect(described_class.new.instructions("tok")).to eq(
      text: "Send /start tok to @MyBot on Telegram", bot_handle: "MyBot"
    )
  end
end
