require "rails_helper"

RSpec.describe InboundMessageRouter do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:identity) { Factories.platform_identity(user: user, platform: "telegram", external_id: "42", external_handle: "@alice") }

  before { clear_enqueued_jobs }

  describe "#call" do
    context "when the external_id is not linked to any Syrus account" do
      it "returns :not_linked without creating a session or message" do
        result = described_class.new(
          platform: "telegram",
          external_id: "99999",
          external_handle: "@stranger",
          message_text: "Hello"
        ).call

        expect(result.status).to eq(:not_linked)
        expect(result.session).to be_nil
        expect(ChatSession.count).to eq(0)
        expect(ChatMessage.count).to eq(0)
      end
    end

    context "when the external_id is linked" do
      before { identity }   # ensure it's created

      it "returns :ok with the session" do
        result = described_class.new(
          platform: "telegram",
          external_id: "42",
          external_handle: "@alice",
          message_text: "Hi Syrus"
        ).call

        expect(result.status).to eq(:ok)
        expect(result.session).to be_a(ChatSession)
        expect(result.session.origin_platform).to eq("telegram")
        expect(result.session.user).to eq(user)
      end

      it "creates a user-role message with the message text and sender" do
        described_class.new(
          platform: "telegram",
          external_id: "42",
          external_handle: "@alice",
          message_text: "Hi Syrus"
        ).call

        message = ChatMessage.where(role: "user").last
        expect(message).to be_present
        expect(message.content["text"]).to eq("Hi Syrus")
        expect(message.sender_user).to eq(user)
      end

      it "enqueues ChatTurnJob for speak_when_spoken_to sessions" do
        expect {
          described_class.new(
            platform: "telegram",
            external_id: "42",
            external_handle: "@alice",
            message_text: "Run the tests"
          ).call
        }.to have_enqueued_job(ChatTurnJob)
      end

      it "reuses the same ChatSession on subsequent calls from the same user/platform" do
        described_class.new(platform: "telegram", external_id: "42", external_handle: "@alice", message_text: "First").call
        described_class.new(platform: "telegram", external_id: "42", external_handle: "@alice", message_text: "Second").call

        expect(ChatSession.where(origin_platform: "telegram", user: user).count).to eq(1)
        expect(ChatMessage.where(role: "user").count).to eq(2)
      end

      it "does not enqueue ChatTurnJob when trigger_policy is not speak_when_spoken_to" do
        session = ChatSession.for_platform(user: user, platform: "telegram")
        session.update_column(:trigger_policy, "proactive")

        expect {
          described_class.new(
            platform: "telegram",
            external_id: "42",
            external_handle: "@alice",
            message_text: "Hello"
          ).call
        }.not_to have_enqueued_job(ChatTurnJob)

        expect(session.reload).not_to be_turn_in_flight
      end

      context "when the session has more than one human participant" do
        before do
          session = ChatSession.for_platform(user: user, platform: "telegram")
          session.chat_participants.create!(user: Factories.user, role: "member")
        end

        it "does not enqueue ChatTurnJob for an unmentioned message" do
          result = nil
          expect {
            result = described_class.new(
              platform: "telegram",
              external_id: "42",
              external_handle: "@alice",
              message_text: "Hello everyone"
            ).call
          }.not_to have_enqueued_job(ChatTurnJob)

          expect(result.session.reload).not_to be_turn_in_flight
        end

        it "enqueues ChatTurnJob when the message mentions @syrus" do
          expect {
            described_class.new(
              platform: "telegram",
              external_id: "42",
              external_handle: "@alice",
              message_text: "hey @syrus can you help?"
            ).call
          }.to have_enqueued_job(ChatTurnJob)
        end
      end

      it "enqueues ChatTurnJob for an unmentioned message when 0-1 human participants" do
        expect {
          described_class.new(
            platform: "telegram",
            external_id: "42",
            external_handle: "@alice",
            message_text: "Hello, no mention here"
          ).call
        }.to have_enqueued_job(ChatTurnJob)
      end
    end
  end
end
