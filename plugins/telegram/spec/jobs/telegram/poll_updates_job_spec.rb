require "rails_helper"
require_relative "../../support/telegram_bot_account"

RSpec.describe Telegram::PollUpdatesJob do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:token) { "bot-token-xyz" }

  before { enable_telegram_plugin! }

  before do
    connect_telegram_bot!(token: token)
    AppSetting.current.update!(telegram_update_offset: 0)
    allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([])
    allow_any_instance_of(Telegram::Client).to receive(:send_message)
    allow_any_instance_of(described_class).to receive(:duplicate_running?).and_return(false)
  end

  after { clear_enqueued_jobs }

  describe "connector status" do
    it "is reported with the telegram platform by PlatformDelivery::Registry" do
      statuses = PlatformDelivery::Registry.start_connectors_with_status!

      expect(statuses).to include(hash_including(name: "Telegram::PollUpdatesJob", platform: "telegram"))
    end
  end

  describe "#configured?" do
    it "returns true when the bot account is connected" do
      job = described_class.new
      expect(job.send(:configured?)).to be true
    end

    it "returns false when the bot account is disconnected" do
      ConnectedAccounts::Account.update_all(status: "revoked")
      job = described_class.new
      expect(job.send(:configured?)).to be false
    end
  end

  describe "re-enqueue behaviour" do
    it "re-enqueues itself after perform when configured" do
      expect { described_class.new.perform }.to have_enqueued_job(described_class)
    end

    it "does not re-enqueue when token is absent" do
      ConnectedAccounts::Account.update_all(status: "revoked")
      expect { described_class.new.perform }.not_to have_enqueued_job(described_class)
    end

    it "re-enqueues with backoff when fetching updates fails" do
      allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_raise(Net::OpenTimeout)
      allow(Rails.logger).to receive(:error)

      expect { described_class.new.perform }
        .to have_enqueued_job(described_class).at(
          a_value_within(1.second).of(PlatformPollingJob::ERROR_RETRY_DELAY.from_now)
        )
    end
  end

  describe "#poll_once" do
    it "logs a failed update, advances its offset, and processes later updates" do
      failed_update = {
        "update_id" => 30,
        "message" => { "from" => { "id" => 99 }, "text" => "poison" }
      }
      later_update = {
        "update_id" => 31,
        "message" => { "from" => { "id" => 99 }, "text" => "next" }
      }
      allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([failed_update, later_update])

      failed_router = instance_double(InboundMessageRouter)
      later_router = instance_double(
        InboundMessageRouter,
        call: InboundMessageRouter::Result.new(status: :ok, session: nil)
      )
      allow(failed_router).to receive(:call).and_raise(ActiveRecord::RecordInvalid)
      allow(InboundMessageRouter).to receive(:new).and_return(failed_router, later_router)
      expect(Rails.logger).to receive(:error).with(include("Telegram update 30"))

      described_class.new.perform

      expect(later_router).to have_received(:call)
      expect(AppSetting.current.reload.telegram_update_offset).to eq(32)
    end

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
        allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([update])

        router = instance_double(InboundMessageRouter, call: InboundMessageRouter::Result.new(status: :ok, session: nil))
        allow(InboundMessageRouter).to receive(:new).and_return(router)

        described_class.new.perform

        expect(InboundMessageRouter).to have_received(:new).with(
          platform: "telegram",
          external_id: "99",
          external_handle: "alice",
          message_text: "Hello Syrus",
          native_message_id: "1",
          conversation_id: "99"
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
        allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([update])
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
        allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([update])
        allow(InboundMessageRouter).to receive(:new).and_return(
          instance_double(InboundMessageRouter, call: InboundMessageRouter::Result.new(status: :not_linked, session: nil))
        )

        telegram = instance_double(Telegram::Client, send_message: nil, get_updates: [update])
        allow(Telegram::Client).to receive(:new).and_return(telegram)

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
        allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([update])

        expect(AppEvents).to receive(:broadcast).with(
          hash_including(user: user, type: "platform_identity_linked")
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
        allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([update])
        allow(AppEvents).to receive(:broadcast)

        telegram = instance_double(Telegram::Client, get_updates: [update], send_message: nil)
        allow(Telegram::Client).to receive(:new).and_return(telegram)

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
        allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([update])

        telegram = instance_double(Telegram::Client, get_updates: [update], send_message: nil)
        allow(Telegram::Client).to receive(:new).and_return(telegram)

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
        allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([update])

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
        allow_any_instance_of(Telegram::Client).to receive(:get_updates).and_return([update])

        expect(InboundMessageRouter).not_to receive(:new)

        described_class.new.perform
      end
    end
  end
end
