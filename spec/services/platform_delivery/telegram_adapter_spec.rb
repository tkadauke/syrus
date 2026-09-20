require "rails_helper"

RSpec.describe PlatformDelivery::TelegramAdapter do
  let(:identity) { Factories.platform_identity(platform: "telegram", external_id: "42") }
  let(:session) { ChatSession.create!(user: identity.user) }

  describe "#deliver" do
    context "with a text message" do
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => "Hello from Syrus" }) }

      it "sends the message text to the identity's external_id" do
        client = instance_double(TelegramClient, send_message: nil)
        allow(TelegramClient).to receive(:new).and_return(client)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(client).to have_received(:send_message).with(chat_id: "42", text: "Hello from Syrus")
      end
    end

    context "with a string content" do
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: "plain text content") }

      it "delivers the string directly" do
        client = instance_double(TelegramClient, send_message: nil)
        allow(TelegramClient).to receive(:new).and_return(client)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(client).to have_received(:send_message).with(chat_id: "42", text: "plain text content")
      end
    end

    context "with blank content" do
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => "" }) }

      it "does not call send_message" do
        allow(TelegramClient).to receive(:new)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(TelegramClient).not_to have_received(:new)
      end
    end

    context "with a long message exceeding 4096 characters" do
      let(:long_text) { ("A" * 100 + "\n") * 50 }
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => long_text }) }

      it "splits the message into chunks and sends each" do
        client = instance_double(TelegramClient, send_message: nil)
        allow(TelegramClient).to receive(:new).and_return(client)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(client).to have_received(:send_message).at_least(:twice)
        expect(client).to have_received(:send_message).with(
          hash_including(chat_id: "42")
        ).at_least(:twice)
      end

      it "ensures no chunk exceeds 4096 characters" do
        chunks_sent = []
        client = instance_double(TelegramClient)
        allow(client).to receive(:send_message) { |args| chunks_sent << args[:text] }
        allow(TelegramClient).to receive(:new).and_return(client)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(chunks_sent).to all(satisfy { |c| c.length <= 4096 })
      end
    end

    context "when the only newline in a 4096-char window is at index 0" do
      let(:long_text) { "\n" + ("A" * 5000) }
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => long_text }) }

      it "does not send an empty chunk" do
        chunks_sent = []
        client = instance_double(TelegramClient)
        allow(client).to receive(:send_message) { |args| chunks_sent << args[:text] }
        allow(TelegramClient).to receive(:new).and_return(client)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(chunks_sent).not_to include("")
        expect(chunks_sent.join).to eq(long_text)
      end
    end

    context "when TelegramClient raises an error" do
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => "Hello" }) }

      it "logs the error and does not re-raise" do
        allow(TelegramClient).to receive(:new).and_raise(RuntimeError, "network failure")

        expect(Rails.logger).to receive(:error).with(include("TelegramAdapter"))
        expect { described_class.new.deliver(message: message, platform_identity: identity) }.not_to raise_error
      end
    end
  end

  describe PlatformDelivery::Registry do
    it "returns a TelegramAdapter for the telegram platform" do
      expect(described_class.for("telegram")).to be_a(PlatformDelivery::TelegramAdapter)
    end
  end
end
