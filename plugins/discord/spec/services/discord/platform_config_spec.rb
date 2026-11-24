require "rails_helper"
require_relative "../../support/discord_bot_account"

RSpec.describe Discord::PlatformConfig do
  before { enable_discord_plugin! }

  describe "#configured?" do
    it "is false until the bot account is connected" do
      expect(described_class.new.configured?).to be false
    end

    it "is true when the bot account is connected" do
      connect_discord_bot!

      expect(described_class.new.configured?).to be true
    end

    it "is false again once the account is disconnected" do
      connect_discord_bot!
      ConnectedAccounts::Account.update_all(status: "revoked")

      expect(described_class.new.configured?).to be false
    end
  end

  describe "#instructions" do
    it "tells the user to DM /link <token> to the bot" do
      instructions = described_class.new.instructions("tok123")

      expect(instructions[:text]).to eq("Send /link tok123 to the Syrus bot on Discord")
    end
  end
end
