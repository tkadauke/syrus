require "rails_helper"

RSpec.describe Discord::GatewayConnectionJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:token) { "bot-token-xyz" }
  let(:default_factory) { described_class.gateway_client_factory }

  around do |ex|
    PluginRecord.find_by!(name: "discord").update!(enabled: true)
    ex.run
  end

  before do
    AppSetting.current.update!(discord_bot_token: token)
    allow_any_instance_of(described_class).to receive(:duplicate_running?).and_return(false)
  end

  after do
    clear_enqueued_jobs
    described_class.gateway_client_factory = default_factory
  end

  def stub_gateway_client(events: [], error: nil)
    client = instance_double(Discord::GatewayClient)
    allow(client).to receive(:run) do |&block|
      raise error if error

      events.each { |event| block.call(event) }
    end
    described_class.gateway_client_factory = ->(token:) { client }
    client
  end

  def message_create(content:, author_id: 99, username: "alice", bot: false, guild_id: nil)
    {
      "t" => "MESSAGE_CREATE",
      "d" => {
        "content" => content,
        "guild_id" => guild_id,
        "author" => { "id" => author_id, "username" => username, "bot" => bot }
      }
    }
  end

  describe "#configured?" do
    it "returns true when discord_bot_token is set" do
      expect(described_class.new.send(:configured?)).to be true
    end

    it "returns false when discord_bot_token is blank" do
      AppSetting.current.update_column(:discord_bot_token, nil)
      expect(described_class.new.send(:configured?)).to be false
    end
  end

  describe "re-enqueue behaviour" do
    it "re-enqueues itself after perform when configured" do
      stub_gateway_client(events: [])
      expect { described_class.new.perform }.to have_enqueued_job(described_class)
    end

    it "does not re-enqueue when the bot token is absent" do
      AppSetting.current.update_column(:discord_bot_token, nil)
      expect { described_class.new.perform }.not_to have_enqueued_job(described_class)
    end

    it "does not connect to the Gateway when the bot token is absent" do
      AppSetting.current.update_column(:discord_bot_token, nil)
      client = stub_gateway_client(events: [])

      described_class.new.perform

      expect(client).not_to have_received(:run)
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
          message_text: "Hello Syrus"
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

        expect { described_class.new.perform }.to have_enqueued_job(described_class)
      end
    end
  end
end
