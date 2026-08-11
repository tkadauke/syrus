require "rails_helper"

RSpec.describe Discord::PlatformAdapter do
  around do |ex|
    PluginRecord.find_by!(name: "discord").update!(enabled: true)
    ex.run
  end

  let(:identity) { Factories.platform_identity(platform: "discord", external_id: "42") }
  let(:session) { ChatSession.create!(user: identity.user) }

  describe ".platform_key" do
    it "is discord" do
      expect(described_class.platform_key).to eq("discord")
    end
  end

  describe ".connector_job_class" do
    it "is Discord::GatewayConnectionJob" do
      expect(described_class.connector_job_class).to eq(Discord::GatewayConnectionJob)
    end
  end

  describe "#deliver" do
    context "with a text message" do
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => "Hello from Syrus" }) }

      it "sends the message text to the identity's external_id" do
        client = instance_double(Discord::Client, send_dm: nil)
        allow(Discord::Client).to receive(:new).and_return(client)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(client).to have_received(:send_dm).with(user_id: "42", text: "Hello from Syrus")
      end
    end

    context "with a string content" do
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: "plain text content") }

      it "delivers the string directly" do
        client = instance_double(Discord::Client, send_dm: nil)
        allow(Discord::Client).to receive(:new).and_return(client)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(client).to have_received(:send_dm).with(user_id: "42", text: "plain text content")
      end
    end

    context "with blank content" do
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => "" }) }

      it "does not call Discord::Client" do
        allow(Discord::Client).to receive(:new)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(Discord::Client).not_to have_received(:new)
      end
    end

    context "with a long message exceeding 2000 characters" do
      let(:long_text) { ("A" * 100 + "\n") * 25 }
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => long_text }) }

      it "splits the message into chunks and sends each" do
        client = instance_double(Discord::Client, send_dm: nil)
        allow(Discord::Client).to receive(:new).and_return(client)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(client).to have_received(:send_dm).at_least(:twice)
        expect(client).to have_received(:send_dm).with(hash_including(user_id: "42")).at_least(:twice)
      end

      it "ensures no chunk exceeds 2000 characters" do
        chunks_sent = []
        client = instance_double(Discord::Client)
        allow(client).to receive(:send_dm) { |args| chunks_sent << args[:text] }
        allow(Discord::Client).to receive(:new).and_return(client)

        described_class.new.deliver(message: message, platform_identity: identity)

        expect(chunks_sent).to all(satisfy { |c| c.length <= 2000 })
      end
    end

    context "when Discord::Client raises an error" do
      let(:message) { ChatMessage.new(chat_session: session, role: "assistant", content: { "text" => "Hello" }) }

      it "logs the error and does not re-raise" do
        allow(Discord::Client).to receive(:new).and_raise(RuntimeError, "network failure")

        expect(Rails.logger).to receive(:error).with(include("Discord::PlatformAdapter"))
        expect { described_class.new.deliver(message: message, platform_identity: identity) }.not_to raise_error
      end
    end
  end

  describe PlatformDelivery::Registry do
    it "returns a Discord::PlatformAdapter for the discord platform" do
      expect(described_class.for("discord")).to be_a(Discord::PlatformAdapter)
    end
  end
end
