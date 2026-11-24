require "rails_helper"
require_relative "support/telegram_bot_account"

# The bot token may only ever exist in the encrypted credential and, briefly,
# in memory inside Telegram::Provider. Telegram puts it in the request path,
# so URLs in exceptions are the likeliest leak. It must never reach logs,
# audit rows, raised errors, or job output.
RSpec.describe "Telegram bot token redaction" do
  let(:token) { "987654:TELEGRAMSECRETTOKEN-xyz" }
  let(:api) { "https://api.telegram.org/bot#{token}" }
  let(:log) { StringIO.new }

  before do
    stub_request(:get, "#{api}/getMe").to_return(status: 200, body: JSON.generate("ok" => true, "result" => { "username" => "syrus_bot" }))
    connect_telegram_bot!(token: token, stub_http: false)
    allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log))
  end

  def account = ConnectedAccounts::TokenBroker.instance_account("telegram_bot")

  def audit_text
    CredentialStore::CredentialAccessEvent.where(credential_id: account.credential_store_credential_id).map { |event| event.attributes.to_s }.join
  end

  it "keeps the token out of the audit trail and the account record" do
    stub_request(:post, "#{api}/sendMessage").to_return(status: 200, body: JSON.generate("ok" => true, "result" => {}))
    Telegram::BotAccess.send_message(chat_id: "1", text: "hello")

    expect(audit_text).not_to include(token)
    expect(account.attributes.to_s).not_to include(token)
    expect(account.credential_store_credential.safe_metadata.to_s).not_to include(token)
  end

  it "scrubs the token from errors that quote the request URL" do
    stub_request(:get, "#{api}/getUpdates").with(query: hash_including({}))
      .to_raise(Net::OpenTimeout.new("execution expired connecting to #{api}/getUpdates"))

    expect { Telegram::BotAccess.get_updates(offset: 0) }.to raise_error(StandardError) do |error|
      expect(error.message).not_to include(token)
    end
    expect(audit_text).not_to include(token)
  end

  it "scrubs the token from API results that echo it" do
    stub_request(:post, "#{api}/sendMessage")
      .to_return(status: 200, body: JSON.generate("ok" => true, "result" => { "text" => "echo #{token}" }))

    expect(Telegram::BotAccess.send_message(chat_id: "1", text: "hello").to_s).not_to include(token)
  end

  it "does not log the token when delivery fails" do
    stub_request(:post, "#{api}/sendMessage").to_raise(Net::OpenTimeout.new("failed #{api}/sendMessage"))
    identity = Factories.platform_identity(platform: "telegram", external_id: "42")
    message = ChatMessage.new(chat_session: ChatSession.create!(user: identity.user), role: "assistant", content: "hi")

    Telegram::PlatformAdapter.new.deliver(message: message, platform_identity: identity)

    expect(log.string).not_to include(token)
  end

  it "does not log the token when polling fails" do
    stub_request(:get, "#{api}/getUpdates").with(query: hash_including({}))
      .to_raise(Net::OpenTimeout.new("failed #{api}/getUpdates"))
    allow_any_instance_of(Telegram::PollUpdatesJob).to receive(:duplicate_running?).and_return(false)

    Telegram::PollUpdatesJob.new.perform

    expect(log.string).to include("Telegram::PollUpdatesJob")
    expect(log.string).not_to include(token)
  end

  it "does not log the token when migration of a legacy value fails" do
    ConnectedAccounts::Account.destroy_all
    AppSetting.current.update!(telegram_bot_token: token)
    stub_request(:get, "#{api}/getMe").to_return(status: 500, body: "token #{token} rejected")
    Telegram::TokenMigration.reset!

    Telegram::TokenMigration.call

    expect(log.string).not_to include(token)
  end
end
