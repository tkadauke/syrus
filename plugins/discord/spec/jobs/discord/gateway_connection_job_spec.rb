require "rails_helper"
require_relative "../../support/discord_bot_account"

RSpec.describe Discord::GatewayConnectionJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:token) { "bot-token-xyz" }
  let(:default_factory) { Discord::Provider.gateway_client_factory }

  around do |ex|
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    enable_discord_plugin!
    ex.run
  ensure
    Rails.cache = original_cache
  end

  before do
    connect_discord_bot!(token: token)
    allow_any_instance_of(described_class).to receive(:duplicate_running?).and_return(false)
  end

  after do
    clear_enqueued_jobs
    Discord::Provider.gateway_client_factory = default_factory
  end

  def stub_gateway_client(events: [], error: nil)
    client = instance_double(
      Discord::GatewayClient,
      fatal_close?: false,
      fatal_close_code: nil,
      fatal_close_reason: nil,
      reset_reconnect_backoff?: false,
      session_established?: false,
      run_outcome: nil
    )
    allow(client).to receive(:run) do |&block|
      raise error if error

      events.each { |event| block.call(event) }
    end
    Discord::Provider.gateway_client_factory = ->(token:, stale_check:) { client }
    client
  end

  def disconnect_bot!
    ConnectedAccounts::Account.update_all(status: "revoked")
  end

  def message_create(content:, author_id: 99, username: "alice", bot: false, guild_id: nil, message_id: 123, channel_id: 456)
    {
      "t" => "MESSAGE_CREATE",
      "d" => {
        "content" => content,
        "id" => message_id,
        "channel_id" => channel_id,
        "guild_id" => guild_id,
        "author" => { "id" => author_id, "username" => username, "bot" => bot }
      }
    }
  end

  describe "#configured?" do
    it "returns true when the bot account is connected" do
      expect(described_class.new.send(:configured?)).to be true
    end

    it "returns false when the bot account is disconnected" do
      disconnect_bot!
      expect(described_class.new.send(:configured?)).to be false
    end
  end

  describe "re-enqueue behaviour" do
    it "re-enqueues itself after perform when configured" do
      stub_gateway_client(events: [])
      expect {
        described_class.new.perform
      }.to have_enqueued_job(described_class).at(a_value_within(1.second).of(described_class::RECONNECT_BACKOFF_SECONDS.seconds.from_now))
    end

    it "does not re-enqueue when the bot token is absent" do
      disconnect_bot!
      expect { described_class.new.perform }.not_to have_enqueued_job(described_class)
    end

    it "does not connect to the Gateway when the bot token is absent" do
      disconnect_bot!
      client = stub_gateway_client(events: [])

      described_class.new.perform

      expect(client).not_to have_received(:run)
    end

    it "backs off repeated startup failures exponentially" do
      stub_gateway_client(events: [])

      described_class.new.perform

      expect {
        described_class.new.perform
      }.to have_enqueued_job(described_class).at(
        a_value_within(1.second).of((described_class::RECONNECT_BACKOFF_SECONDS * 2).seconds.from_now)
      )
    end

    it "resets the backoff after a Gateway session was established" do
      stub_gateway_client(events: [])
      described_class.new.perform

      client = stub_gateway_client(events: [])
      allow(client).to receive(:reset_reconnect_backoff?).and_return(true)
      described_class.new.perform
      clear_enqueued_jobs

      expect {
        stub_gateway_client(events: [])
        described_class.new.perform
      }.to have_enqueued_job(described_class).at(
        a_value_within(1.second).of(described_class::RECONNECT_BACKOFF_SECONDS.seconds.from_now)
      )
    end

    it "keeps growing the backoff when a post-session reconnect loop is exhausted" do
      stub_gateway_client(events: [])
      described_class.new.perform

      exhausted_client = stub_gateway_client(events: [])
      allow(exhausted_client).to receive(:session_established?).and_return(true)
      allow(exhausted_client).to receive(:reset_reconnect_backoff?).and_return(false)

      expect {
        described_class.new.perform
      }.to have_enqueued_job(described_class).at(
        a_value_within(1.second).of((described_class::RECONNECT_BACKOFF_SECONDS * 2).seconds.from_now)
      )
    end

    it "does not re-enqueue after a fatal Gateway close" do
      client = stub_gateway_client(events: [])
      allow(client).to receive(:fatal_close?).and_return(true)
      allow(client).to receive(:fatal_close_code).and_return(4014)
      allow(client).to receive(:fatal_close_reason).and_return("Disallowed intents")
      allow(Rails.logger).to receive(:error)

      expect { described_class.new.perform }.not_to have_enqueued_job(described_class)
      expect(Rails.logger).to have_received(:error).with(include("fatal code 4014"))
    end
  end

  describe "#poll_once" do
    context "with a MESSAGE_CREATE DM from a linked user" do
      let(:identity) { Factories.platform_identity(user: user, platform: "discord", external_id: "99") }

      before { identity }

      it "routes the message via InboundMessageRouter" do
        stub_gateway_client(events: [ message_create(content: "Hello Syrus") ])

        router = instance_double(InboundMessageRouter, call: InboundMessageRouter::Result.new(status: :ok, session: nil))
        allow(InboundMessageRouter).to receive(:new).and_return(router)

        described_class.new.perform

        expect(InboundMessageRouter).to have_received(:new).with(
          platform: "discord",
          external_id: "99",
          external_handle: "alice",
          message_text: "Hello Syrus",
          native_message_id: "123",
          conversation_id: "456"
        )
        expect(router).to have_received(:call)
      end
    end

    context "with a MESSAGE_CREATE DM from an unlinked sender" do
      it "sends a 'not linked' reply" do
        stub_gateway_client(events: [ message_create(content: "hello", author_id: 777, username: "stranger") ])
        allow(InboundMessageRouter).to receive(:new).and_return(
          instance_double(InboundMessageRouter, call: InboundMessageRouter::Result.new(status: :not_linked, session: nil))
        )

        discord = instance_double(Discord::Client, send_dm: nil)
        allow(Discord::Client).to receive(:new).and_return(discord)

        described_class.new.perform

        expect(discord).to have_received(:send_dm).with(user_id: 777, text: include("don't recognize"))
      end
    end

    context "with a /link linking message" do
      let(:verifier) { Rails.application.message_verifier(:platform_linking) }
      let(:link_token) { verifier.generate({ "user_id" => user.id, "platform" => "discord" }, expires_in: 15.minutes) }

      it "creates a PlatformIdentity and broadcasts the linked event" do
        stub_gateway_client(events: [ message_create(content: "/link #{link_token}", author_id: 555, username: "linker") ])

        expect(AppEvents).to receive(:broadcast).with(hash_including(user: user, type: "platform_identity_linked"))

        described_class.new.perform

        identity = PlatformIdentity.find_by!(platform: "discord", external_id: "555")
        expect(identity.user).to eq(user)
        expect(identity.external_handle).to eq("linker")
      end

      it "sends a success reply after linking" do
        stub_gateway_client(events: [ message_create(content: "/link #{link_token}", author_id: 555, username: "linker") ])
        allow(AppEvents).to receive(:broadcast)

        discord = instance_double(Discord::Client, send_dm: nil)
        allow(Discord::Client).to receive(:new).and_return(discord)

        described_class.new.perform

        expect(discord).to have_received(:send_dm).with(user_id: 555, text: include("connected"))
      end

      it "sends an error reply when the token is expired or invalid" do
        stub_gateway_client(events: [ message_create(content: "/link bad-token", author_id: 666, username: "hacker") ])

        discord = instance_double(Discord::Client, send_dm: nil)
        allow(Discord::Client).to receive(:new).and_return(discord)

        described_class.new.perform

        expect(discord).to have_received(:send_dm).with(user_id: 666, text: include("expired or is invalid"))
      end
    end

    context "with non-DM or bot-authored messages" do
      it "ignores messages posted in a guild channel" do
        stub_gateway_client(events: [ message_create(content: "irrelevant", guild_id: "1234") ])

        expect(InboundMessageRouter).not_to receive(:new)

        described_class.new.perform
      end

      it "ignores messages authored by a bot" do
        stub_gateway_client(events: [ message_create(content: "irrelevant", bot: true) ])

        expect(InboundMessageRouter).not_to receive(:new)

        described_class.new.perform
      end

      it "ignores dispatch events that are not MESSAGE_CREATE" do
        stub_gateway_client(events: [ { "t" => "TYPING_START", "d" => {} } ])

        expect(InboundMessageRouter).not_to receive(:new)

        described_class.new.perform
      end
    end

    context "when the Gateway connection errors" do
      it "logs the error and does not re-raise" do
        stub_gateway_client(error: RuntimeError.new("connection reset"))

        expect(Rails.logger).to receive(:error).with(include("Discord::GatewayConnectionJob"))
        expect { described_class.new.perform }.not_to raise_error
      end

      it "re-enqueues itself so the next attempt reconnects" do
        stub_gateway_client(error: RuntimeError.new("connection reset"))
        allow(Rails.logger).to receive(:error)

        expect {
          described_class.new.perform
        }.to have_enqueued_job(described_class).at(a_value_within(1.second).of(described_class::RECONNECT_BACKOFF_SECONDS.seconds.from_now))
      end
    end
  end

  describe "token rotation and revocation" do
    def capture_gateway_clients
      sessions = []
      Discord::Provider.gateway_client_factory = lambda do |token:, stale_check:|
        client = instance_double(Discord::GatewayClient, fatal_close_code: nil, fatal_close_reason: nil,
          reset_reconnect_backoff?: false, run_outcome: nil)
        allow(client).to receive(:run) { sessions << { token: token, stale_check: stale_check } }
        client
      end
      sessions
    end

    it "gives each Gateway session the token that is current when it starts" do
      sessions = capture_gateway_clients
      described_class.new.perform
      ConnectedAccounts::TokenBroker.connect!(provider: "discord_bot", token: "rotated-token-0002", label: "Syrus bot",
        admin: User.where(global_role: "admin").first)
      described_class.new.perform

      expect(sessions.map { |session| session[:token] }).to eq([ token, "rotated-token-0002" ])
    end

    it "reports the session stale as soon as the credential is rotated, and not before" do
      sessions = capture_gateway_clients
      described_class.new.perform
      stale_check = sessions.first[:stale_check]

      expect(stale_check.call).to be(false)
      ConnectedAccounts::TokenBroker.connect!(provider: "discord_bot", token: "rotated-token-0002", label: "Syrus bot",
        admin: User.where(global_role: "admin").first)
      expect(stale_check.call).to be(true)
    end

    it "reports the session stale when the account is disconnected" do
      sessions = capture_gateway_clients
      described_class.new.perform
      ConnectedAccounts::Account.update_all(status: "revoked")

      expect(sessions.first[:stale_check].call).to be(true)
    end

    it "reconnects immediately, without backoff, after the Gateway ends a session because of a rotation" do
      client = stub_gateway_client(events: [])
      allow(client).to receive(:run_outcome).and_return(:credential_changed)
      Rails.cache.write(described_class::RECONNECT_ATTEMPT_CACHE_KEY, 3)

      expect { described_class.new.perform }.to have_enqueued_job(described_class).at(nil)
      expect(Rails.cache.read(described_class::RECONNECT_ATTEMPT_CACHE_KEY)).to be_nil
    end

    it "stops reconnecting when the account was revoked mid-session" do
      client = stub_gateway_client(events: [])
      allow(client).to receive(:run_outcome).and_return(:credential_changed)
      allow(client).to receive(:run) { ConnectedAccounts::Account.update_all(status: "revoked") }

      expect { described_class.new.perform }.not_to have_enqueued_job(described_class)
    end
  end
end
