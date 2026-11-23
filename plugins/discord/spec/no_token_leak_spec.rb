require "rails_helper"
require_relative "support/discord_bot_account"

# The bot token may only ever exist in the encrypted credential and, briefly,
# in memory inside Discord::Provider. It must never reach logs, audit rows,
# raised errors, job output, or anything a chat transcript could contain.
RSpec.describe "Discord bot token redaction" do
  let(:token) { "DISCORDSECRETTOKEN.abc.0123456789" }
  let(:log) { StringIO.new }
  let(:users_me) { "https://discord.com/api/v10/users/@me" }

  before do
    stub_request(:get, users_me).to_return(status: 200, body: JSON.generate("username" => "SyrusBot"))
    connect_discord_bot!(token: token, stub_http: false)
    allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log))
  end

  def account = ConnectedAccounts::TokenBroker.instance_account("discord_bot")

  def audit_text
    CredentialStore::CredentialAccessEvent.where(credential_id: account.credential_store_credential_id).map { |event| event.attributes.to_s }.join
  end

  it "keeps the token out of the audit trail and the account record" do
    stub_request(:post, "https://discord.com/api/v10/users/@me/channels").to_return(status: 200, body: JSON.generate("id" => "c"))
    stub_request(:post, "https://discord.com/api/v10/channels/c/messages").to_return(status: 200, body: JSON.generate("id" => "m"))
    Discord::BotAccess.send_dm(user_id: "1", text: "hello")

    expect(audit_text).not_to include(token)
    expect(account.attributes.to_s).not_to include(token)
    expect(account.credential_store_credential.safe_metadata.to_s).not_to include(token)
  end

  it "scrubs the token from errors raised through the broker" do
    allow_any_instance_of(Discord::Client).to receive(:send_dm).and_raise("upstream said #{token} is invalid")

    expect { Discord::BotAccess.send_dm(user_id: "1", text: "hello") }.to raise_error(StandardError) do |error|
      expect(error.message).not_to include(token)
    end
    expect(audit_text).not_to include(token)
  end

  it "scrubs the token from API results that echo it" do
    stub_request(:post, "https://discord.com/api/v10/users/@me/channels").to_return(status: 200, body: JSON.generate("id" => "c"))
    stub_request(:post, "https://discord.com/api/v10/channels/c/messages")
      .to_return(status: 200, body: JSON.generate("id" => "m", "content" => "echo #{token}"))

    result = Discord::BotAccess.send_dm(user_id: "1", text: "hello")

    expect(result.to_s).not_to include(token)
  end

  it "does not log the token when delivery fails" do
    adapter = Discord::PlatformAdapter.new
    allow(Discord::BotAccess).to receive(:send_dm).and_call_original
    allow_any_instance_of(Discord::Client).to receive(:send_dm).and_raise("boom #{token}")
    identity = Factories.platform_identity(platform: "discord", external_id: "42")
    message = ChatMessage.new(chat_session: ChatSession.create!(user: identity.user), role: "assistant", content: "hi")

    adapter.deliver(message: message, platform_identity: identity)

    expect(log.string).to include("Discord::PlatformAdapter#deliver")
    expect(log.string).not_to include(token)
  end

  it "does not log the token when a Gateway session fails" do
    Discord::Provider.gateway_client_factory = lambda do |token:, stale_check:|
      instance_double(Discord::GatewayClient).tap { |client| allow(client).to receive(:run).and_raise("socket error for #{token}") }
    end
    allow_any_instance_of(Discord::GatewayConnectionJob).to receive(:duplicate_running?).and_return(false)

    Discord::GatewayConnectionJob.new.perform

    expect(log.string).to include("Discord::GatewayConnectionJob")
    expect(log.string).not_to include(token)
  ensure
    Discord::Provider.gateway_client_factory = ->(token:, stale_check:) { Discord::GatewayClient.new(token: token, stale_check: stale_check) }
  end

  it "does not log the token when migration of a legacy value fails" do
    ConnectedAccounts::Account.destroy_all
    AppSetting.current.update!(discord_bot_token: token)
    stub_request(:get, users_me).to_return(status: 500, body: "token #{token} rejected")
    Discord::TokenMigration.reset!

    Discord::TokenMigration.call

    expect(log.string).not_to include(token)
  end

  it "never renders the token through Access inspection" do
    seen = nil
    allow_any_instance_of(Discord::Client).to receive(:send_dm) { seen = nil }
    ConnectedAccounts::AccountClient.with_access(account: account, acting_mode: :as_service, scopes: [ "discord.bot" ],
      purpose: "inspect", target: Discord::BotAccess::TARGET,
      context: McpToolContext.new(surface: :api, role: "system_service", user: account.credential_store_credential.created_by,
        permission_authorization: { system_service_identity: "discord.platform" })) { |access| seen = [ access.to_s, access.inspect, access.to_json ] }

    expect(seen.join).not_to include(token)
  end
end
