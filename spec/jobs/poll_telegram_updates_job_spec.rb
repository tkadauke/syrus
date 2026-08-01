require "rails_helper"

RSpec.describe PollTelegramUpdatesJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:token) { "bot-token-xyz" }

  before do
    AppSetting.current.update!(telegram_bot_token: token, telegram_bot_handle: "MySyrusBot", telegram_update_offset: 0)
    allow_any_instance_of(TelegramClient).to receive(:get_updates).and_return([])
    allow_any_instance_of(TelegramClient).to receive(:send_message)
    allow_any_instance_of(described_class).to receive(:duplicate_running?).and_return(false)
  end

  after { clear_enqueued_jobs }

  describe "#configured?" do
    it "returns true when telegram_bot_token and telegram_bot_handle are set" do
      job = described_class.new
      expect(job.send(:configured?)).to be true
    end

    it "returns false when telegram_bot_token is blank" do
      AppSetting.current.update_column(:telegram_bot_token, nil)
      job = described_class.new
      expect(job.send(:configured?)).to be false
    end

    it "returns false when telegram_bot_handle is blank" do
      AppSetting.current.update!(telegram_bot_handle: nil)
      job = described_class.new
      expect(job.send(:configured?)).to be false
    end
  end

  describe "re-enqueue behaviour" do
    it "re-enqueues itself after perform when configured" do
      expect { described_class.new.perform }.to have_enqueued_job(described_class)
    end

    it "does not re-enqueue when Telegram is not configured" do
      AppSetting.current.update_column(:telegram_bot_token, nil)
      expect { described_class.new.perform }.not_to have_enqueued_job(described_class)
    end
  end

  describe "#poll_once" do
    context "with a text message from a linked user" do
      let(:identity) { Factories.platform_identity(user: user, platform: "telegram", external_id: "99") }

      before { identity }

      it "routes the message via InboundMessageRouter" do
        update = {
          "update_id" => 1,
          "message" => {
            "from" => { "id" => 99, "username" => "alice" },
            "text" => "Hello Syrus"
          }
        }
        allow_any_instance_of(TelegramClient).to receive(:get_updates).and_return([update])

        router = instance_double(InboundMessageRouter, call: InboundMessageRouter::Result.new(status: :ok, session: nil))
        allow(InboundMessageRouter).to receive(:new).and_return(router)

        described_class.new.perform

        expect(InboundMessageRouter).to have_received(:new).with(
          platform: "telegram",
          external_id: "99",
          external_handle: "alice",
          message_text: "Hello Syrus"
        )
        expect(router).to have_received(:call)
      end

      it "advances telegram_update_offset after processing" do
        update = {
          "update_id" => 42,
          "message" => {
            "from" => { "id" => 99, "username" => "alice" },
            "text" => "ping"
          }
        }
        allow_any_instance_of(TelegramClient).to receive(:get_updates).and_return([update])
        allow(InboundMessageRouter).to receive(:new).and_return(
          instance_double(InboundMessageRouter, call: InboundMessageRouter::Result.new(status: :ok, session: nil))
        )

        described_class.new.perform

        expect(AppSetting.current.reload.telegram_update_offset).to eq(43)
      end
    end

    context "with a text message from an unlinked sender" do
      it "sends a 'not linked' reply" do
        update = {
          "update_id" => 5,
          "message" => {
            "from" => { "id" => 777, "username" => "stranger" },
            "text" => "hello"
          }
        }
        allow_any_instance_of(TelegramClient).to receive(:get_updates).and_return([update])
        allow(InboundMessageRouter).to receive(:new).and_return(
          instance_double(InboundMessageRouter, call: InboundMessageRouter::Result.new(status: :not_linked, session: nil))
        )

        telegram = instance_double(TelegramClient, send_message: nil, get_updates: [update])
        allow(TelegramClient).to receive(:new).and_return(telegram)

        described_class.new.perform

        expect(telegram).to have_received(:send_message).with(
          chat_id: 777,
          text: include("don't recognize")
        )
      end
    end

    context "with a /start linking message" do
      let(:verifier) { Rails.application.message_verifier(:platform_linking) }
      let(:link_token) { verifier.generate({ "user_id" => user.id, "platform" => "telegram" }, expires_in: 15.minutes) }

      it "creates a PlatformIdentity and broadcasts the linked event" do
        update = {
          "update_id" => 10,
          "message" => {
            "from" => { "id" => 555, "username" => "linker" },
            "text" => "/start #{link_token}"
          }
        }
        allow_any_instance_of(TelegramClient).to receive(:get_updates).and_return([update])

        expect(AppEvents).to receive(:broadcast).with(
          hash_including(
            user: user,
            type: "platform_identity_linked",
            resource: "platform_identity",
            payload: hash_including(
              platform_identities: array_including(hash_including(platform: "telegram")),
              available_platforms: array_including(hash_including(platform: "telegram"))
            )
          )
        )

        described_class.new.perform

        identity = PlatformIdentity.find_by!(platform: "telegram", external_id: "555")
        expect(identity.user).to eq(user)
        expect(identity.external_handle).to eq("linker")
      end

      it "sends a success reply after linking" do
        update = {
          "update_id" => 10,
          "message" => {
            "from" => { "id" => 555, "username" => "linker" },
            "text" => "/start #{link_token}"
          }
        }
        allow_any_instance_of(TelegramClient).to receive(:get_updates).and_return([update])
        allow(AppEvents).to receive(:broadcast)

        telegram = instance_double(TelegramClient, get_updates: [update], send_message: nil)
        allow(TelegramClient).to receive(:new).and_return(telegram)

        described_class.new.perform

        expect(telegram).to have_received(:send_message).with(
          chat_id: 555,
          text: include("connected")
        )
      end

      it "sends an error reply when the token is expired or invalid" do
        update = {
          "update_id" => 11,
          "message" => {
            "from" => { "id" => 666, "username" => "hacker" },
            "text" => "/start bad-token"
          }
        }
        allow_any_instance_of(TelegramClient).to receive(:get_updates).and_return([update])

        telegram = instance_double(TelegramClient, get_updates: [update], send_message: nil)
        allow(TelegramClient).to receive(:new).and_return(telegram)

        described_class.new.perform

        expect(telegram).to have_received(:send_message).with(
          chat_id: 666,
          text: include("expired or is invalid")
        )
      end
    end

    context "with non-text updates" do
      it "ignores updates without a message field" do
        update = { "update_id" => 20, "channel_post" => { "text" => "irrelevant" } }
        allow_any_instance_of(TelegramClient).to receive(:get_updates).and_return([update])

        expect(InboundMessageRouter).not_to receive(:new)

        described_class.new.perform
      end

      it "ignores messages without a text field" do
        update = {
          "update_id" => 21,
          "message" => {
            "from" => { "id" => 1, "username" => "photo_sender" },
            "photo" => [{ "file_id" => "abc" }]
          }
        }
        allow_any_instance_of(TelegramClient).to receive(:get_updates).and_return([update])

        expect(InboundMessageRouter).not_to receive(:new)

        described_class.new.perform
      end
    end
  end
end
