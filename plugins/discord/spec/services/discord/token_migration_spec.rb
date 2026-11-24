require "rails_helper"
require_relative "../../support/discord_bot_account"

RSpec.describe Discord::TokenMigration do
  let(:token) { "legacy-discord-token-0001" }
  let(:users_me) { "https://discord.com/api/v10/users/@me" }
  let!(:admin) { Factories.user(global_role: "admin") }

  before do
    enable_discord_plugin!
    described_class.reset!
  end

  def account = ConnectedAccounts::TokenBroker.instance_account("discord_bot")

  it "does nothing on a fresh instance" do
    expect(described_class.call).to eq(:nothing_to_migrate)
    expect(account).to be_nil
  end

  context "with an existing token" do
    before { AppSetting.current.update!(discord_bot_token: token) }

    it "creates the instance account, verifies it, then clears the legacy value" do
      stub_request(:get, users_me).with(headers: { "Authorization" => "Bot #{token}" })
        .to_return(status: 200, body: JSON.generate("username" => "SyrusBot"))

      expect(described_class.call).to eq(:migrated)

      expect(account).to have_attributes(owner_kind: "instance", status: "connected", display_label: "SyrusBot",
        acting_modes: [ "as_service" ])
      expect(account.credential_store_credential.payload).to include(token)
      expect(AppSetting.current.reload.discord_bot_token).to be_nil
      expect(Discord::BotAccess.legacy_pending?).to be(false)
    end

    it "is idempotent on a rerun" do
      stub_request(:get, users_me).to_return(status: 200, body: JSON.generate("username" => "SyrusBot"))

      expect(described_class.call).to eq(:migrated)
      credential_id = account.credential_store_credential_id
      expect(described_class.call).to eq(:nothing_to_migrate)

      expect(ConnectedAccounts::Account.where(provider: "discord_bot").count).to eq(1)
      expect(account.credential_store_credential_id).to eq(credential_id)
    end

    it "finishes clearing a leftover legacy value when the account already exists" do
      stub_request(:get, users_me).to_return(status: 200, body: JSON.generate("username" => "SyrusBot"))
      connect_discord_bot!(token: token, stub_http: false)

      expect(described_class.call).to eq(:migrated)
      expect(ConnectedAccounts::Account.where(provider: "discord_bot").count).to eq(1)
      expect(AppSetting.current.reload.discord_bot_token).to be_nil
    end

    it "retires a leftover legacy value without reading it once an account is connected" do
      stub_request(:get, users_me).to_return(status: 200, body: JSON.generate("username" => "SyrusBot"))
      connect_discord_bot!(token: token, stub_http: false)
      expect(AppSetting).not_to receive(:discord_bot_token)

      expect(Discord::BotAccess.configured?).to be(true)

      expect(AppSetting.current.reload.discord_bot_token).to be_nil
    end

    it "keeps the token and keeps delivery working when Discord rejects it" do
      stub_request(:get, users_me).to_return(status: 401, body: "{}")
      logged = []
      allow(Rails.logger).to receive(:warn) { |message| logged << message }

      expect(described_class.call).to eq(:failed)

      expect(account).to be_nil
      expect(AppSetting.current.reload.discord_bot_token).to eq(token)
      expect(Discord::BotAccess.legacy_pending?).to be(true)
      expect(logged.join).not_to include(token)
    end

    it "keeps the legacy token and leaves no account when verification of the new account fails" do
      stub_request(:get, users_me).to_return(status: 200, body: JSON.generate("username" => "SyrusBot"))
      allow(Discord::BotAccess).to receive(:brokered).and_raise(ConnectedAccounts::AccountClient::Denied, "connected account not found")

      expect(described_class.call).to eq(:failed)

      expect(account).to be_nil
      expect(ConnectedAccounts::Account.where(provider: "discord_bot")).to be_empty
      expect(CredentialStore::Credential.active.where(credential_type: ConnectedAccounts::AccountClient::CREDENTIAL_TYPE)).to be_empty
      expect(AppSetting.current.reload.discord_bot_token).to eq(token)
    end

    it "fails without losing the token when no administrator exists to own the credential" do
      User.where(global_role: "admin").destroy_all

      expect(described_class.call).to eq(:failed)
      expect(AppSetting.current.reload.discord_bot_token).to eq(token)
    end

    it "only retries a failed migration after the retry interval" do
      stub_request(:get, users_me).to_return(status: 401, body: "{}")

      described_class.call_if_due
      described_class.call_if_due

      expect(a_request(:get, users_me)).to have_been_made.once
    end
  end
end
