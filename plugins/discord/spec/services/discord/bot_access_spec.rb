require "rails_helper"
require_relative "../../support/discord_bot_account"

RSpec.describe Discord::BotAccess do
  let(:token) { "discord-secret-token-0001" }
  let(:dm_stubs) do
    stub_request(:post, "https://discord.com/api/v10/users/@me/channels")
      .with(headers: { "Authorization" => "Bot #{token}" }).to_return(status: 200, body: JSON.generate("id" => "chan-1"))
    stub_request(:post, "https://discord.com/api/v10/channels/chan-1/messages")
      .with(headers: { "Authorization" => "Bot #{token}" }, body: JSON.generate("content" => "hello"))
      .to_return(status: 200, body: JSON.generate("id" => "msg-1"))
  end

  before { enable_discord_plugin! }

  describe "brokered REST calls" do
    before do
      stub_request(:get, "https://discord.com/api/v10/users/@me").to_return(status: 200, body: JSON.generate("username" => "SyrusBot"))
      connect_discord_bot!(token: token, stub_http: false)
    end

    it "sends a DM with the token taken from the instance account for the length of the call" do
      dm_stubs

      expect(described_class.send_dm(user_id: "42", text: "hello")).to include("id" => "msg-1")
      expect(a_request(:post, "https://discord.com/api/v10/channels/chan-1/messages")).to have_been_made.once
    end

    it "audits the system service identity and purpose, never the token" do
      dm_stubs
      described_class.send_dm(user_id: "42", text: "hello")

      credential = ConnectedAccounts::TokenBroker.instance_account("discord_bot").credential_store_credential
      lease = credential.access_events.where(action: "lease", result: "allowed").last
      expect(lease.metadata).to include("system_service_identity" => "discord.platform", "acting_mode" => "as_service",
        "purpose" => Discord::BotAccess::SEND_PURPOSE)
      expect(credential.access_events.map { |event| event.attributes.to_s }.join).not_to include(token)
    end

    it "never reads the legacy application setting once an account exists" do
      dm_stubs
      expect(AppSetting).not_to receive(:discord_bot_token)

      described_class.send_dm(user_id: "42", text: "hello")
      expect(described_class.configured?).to be(true)
    end

    it "refuses a call after the account is disconnected, even if a legacy value is still stored" do
      AppSetting.current.update_column(:discord_bot_token, "legacy-token-value")
      ConnectedAccounts::Account.update_all(status: "revoked")

      expect(described_class.configured?).to be(false)
      expect { described_class.send_dm(user_id: "42", text: "hello") }.to raise_error(Discord::BotAccess::NotConfigured)
    end

    it "uses the new token after the operator rotates it" do
      ConnectedAccounts::TokenBroker.connect!(provider: "discord_bot", token: "rotated-token-0002", label: nil,
        admin: User.where(global_role: "admin").first)
      stub_request(:post, "https://discord.com/api/v10/users/@me/channels")
        .with(headers: { "Authorization" => "Bot rotated-token-0002" }).to_return(status: 200, body: JSON.generate("id" => "chan-2"))
      stub_request(:post, "https://discord.com/api/v10/channels/chan-2/messages")
        .with(headers: { "Authorization" => "Bot rotated-token-0002" }).to_return(status: 200, body: JSON.generate("id" => "msg-2"))

      expect(described_class.send_dm(user_id: "42", text: "hi")).to include("id" => "msg-2")
    end
  end

  describe "without an account" do
    it "is not configured and raises when nothing is stored" do
      expect(described_class.configured?).to be(false)
      expect { described_class.send_dm(user_id: "42", text: "hello") }.to raise_error(Discord::BotAccess::NotConfigured)
    end

    it "keeps delivering with an unmigrated legacy token until an account exists" do
      AppSetting.current.update!(discord_bot_token: token)
      allow(Discord::TokenMigration).to receive(:call_if_due)
      dm_stubs

      expect(described_class.configured?).to be(true)
      expect(described_class.send_dm(user_id: "42", text: "hello")).to include("id" => "msg-1")
    end
  end
end
