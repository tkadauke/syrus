require "rails_helper"
require_relative "../../support/telegram_bot_account"

RSpec.describe Telegram::BotAccess do
  let(:token) { "123456:telegram-secret-token" }
  let(:api) { "https://api.telegram.org/bot#{token}" }

  before { enable_telegram_plugin! }

  describe "brokered REST calls" do
    before do
      stub_request(:get, "#{api}/getMe").to_return(status: 200, body: JSON.generate("ok" => true, "result" => { "username" => "syrus_bot" }))
      connect_telegram_bot!(token: token, stub_http: false)
    end

    it "polls updates with the token taken from the instance account for the length of the call" do
      stub_request(:get, "#{api}/getUpdates").with(query: { offset: 7, timeout: 25 })
        .to_return(status: 200, body: JSON.generate("ok" => true, "result" => [ { "update_id" => 7 } ]))

      expect(described_class.get_updates(offset: 7)).to eq([ { "update_id" => 7 } ])
    end

    it "sends a message and audits the system service identity and purpose, never the token" do
      stub_request(:post, "#{api}/sendMessage").with(body: JSON.generate("chat_id" => "42", "text" => "hi"))
        .to_return(status: 200, body: JSON.generate("ok" => true, "result" => { "message_id" => 1 }))

      described_class.send_message(chat_id: "42", text: "hi")

      credential = ConnectedAccounts::TokenBroker.instance_account("telegram_bot").credential_store_credential
      lease = credential.access_events.where(action: "lease", result: "allowed").last
      expect(lease.metadata).to include("system_service_identity" => "telegram.platform", "acting_mode" => "as_service",
        "purpose" => "deliver a Telegram message")
      expect(credential.access_events.map { |event| event.attributes.to_s }.join).not_to include(token)
    end

    it "resolves and caches the bot handle from the bot itself" do
      around_cache = Rails.cache
      Rails.cache = ActiveSupport::Cache::MemoryStore.new

      2.times { expect(described_class.handle).to eq("syrus_bot") }
      expect(a_request(:get, "#{api}/getMe")).to have_been_made.times(2) # once to connect, once to resolve; the second read is cached
    ensure
      Rails.cache = around_cache
    end

    it "never reads the legacy application setting once an account exists" do
      stub_request(:post, "#{api}/sendMessage").to_return(status: 200, body: JSON.generate("ok" => true, "result" => {}))
      expect(AppSetting).not_to receive(:telegram_bot_token)
      expect(AppSetting).not_to receive(:telegram_bot_handle)

      described_class.send_message(chat_id: "42", text: "hi")
      expect(described_class.configured?).to be(true)
      described_class.handle
    end

    it "uses the new token after the operator rotates it" do
      stub_request(:get, "https://api.telegram.org/bot654321:rotated-token/getMe")
        .to_return(status: 200, body: JSON.generate("ok" => true, "result" => { "username" => "syrus_bot" }))
      ConnectedAccounts::TokenBroker.connect!(provider: "telegram_bot", token: "654321:rotated-token", label: nil,
        admin: User.where(global_role: "admin").first)
      stub_request(:post, "https://api.telegram.org/bot654321:rotated-token/sendMessage")
        .to_return(status: 200, body: JSON.generate("ok" => true, "result" => { "message_id" => 2 }))

      expect(described_class.send_message(chat_id: "42", text: "hi")).to include("ok" => true)
    end

    it "refuses a call after the account is disconnected, even if a legacy value is still stored" do
      AppSetting.current.update_column(:telegram_bot_token, "legacy-token-value")
      ConnectedAccounts::Account.update_all(status: "revoked")

      expect(described_class.configured?).to be(false)
      expect { described_class.get_updates(offset: 0) }.to raise_error(Telegram::BotAccess::NotConfigured)
    end
  end

  describe "without an account" do
    it "is not configured and raises when nothing is stored" do
      expect(described_class.configured?).to be(false)
      expect { described_class.send_message(chat_id: "42", text: "hi") }.to raise_error(Telegram::BotAccess::NotConfigured)
    end

    it "keeps delivering with an unmigrated legacy token until an account exists" do
      AppSetting.current.update!(telegram_bot_token: token, telegram_bot_handle: "legacy_bot")
      allow(Telegram::TokenMigration).to receive(:call_if_due)
      stub_request(:post, "#{api}/sendMessage").to_return(status: 200, body: JSON.generate("ok" => true, "result" => {}))

      expect(described_class.configured?).to be(true)
      expect(described_class.handle).to eq("legacy_bot")
      expect(described_class.send_message(chat_id: "42", text: "hi")).to include("ok" => true)
    end
  end
end
