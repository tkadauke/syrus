require "rails_helper"

RSpec.describe ChatMessage do
  include ActiveJob::TestHelper

  let(:repo) { Factories.repository }
  let(:session) { ChatSession.create!(repository: repo, user: repo.user) }

  before do
    clear_enqueued_jobs
  end

  it "creates with valid attributes" do
    message = described_class.create!(
      chat_session: session,
      role: "tool_use",
      content: { "name" => "inspect_repo" },
      tool_name: "inspect_repo",
      tool_use_id: "toolu_123"
    )

    expect(message).to be_persisted
    expect(message.content).to eq("name" => "inspect_repo")
  end

  it "allows each transcript role" do
    described_class::ROLES.each do |role|
      message = described_class.new(chat_session: session, role: role, content: {})
      expect(message).to be_valid
    end
  end

  it "requires a chat session" do
    message = described_class.new(role: "user", content: { "text" => "Hello" })

    expect(message).not_to be_valid
    expect(message.errors[:chat_session]).to be_present
  end

  it "validates role against the chat transcript roles" do
    message = described_class.new(chat_session: session, role: "oracle", content: { "text" => "Nope" })

    expect(message).not_to be_valid
    expect(message.errors[:role]).to be_present
  end

  it "requires content" do
    message = described_class.new(chat_session: session, role: "assistant", content: nil)

    expect(message).not_to be_valid
    expect(message.errors[:content]).to be_present
  end

  it "destroys bookmarks with the message" do
    message = described_class.create!(chat_session: session, role: "assistant", content: { "text" => "Salve" })
    bookmark = message.bookmarks.create!(label: "Greeting", kind: "topic")

    expect { message.destroy }.to change { ChatBookmark.where(id: bookmark.id).count }.by(-1)
  end

  it "only treats user and assistant rows as manually bookmarkable" do
    bookmarkable_roles = described_class::ROLES.select do |role|
      described_class.new(chat_session: session, role: role, content: {}).bookmarkable?
    end

    expect(bookmarkable_roles).to eq(%w[user assistant])
  end

  it "destroys pins with the message" do
    message = described_class.create!(chat_session: session, role: "assistant", content: { "text" => "Salve" })
    pin = message.pins.create!

    expect { message.destroy }.to change { ChatMessagePin.where(id: pin.id).count }.by(-1)
  end

  it "only treats user and assistant rows as pinnable" do
    pinnable_roles = described_class::ROLES.select do |role|
      described_class.new(chat_session: session, role: role, content: {}).pinnable?
    end

    expect(pinnable_roles).to eq(%w[user assistant])
  end

  describe "#preview_text" do
    it "extracts text from legacy flat content" do
      message = described_class.new(chat_session: session, role: "user", content: { "text" => "Fix the aqueduct." })

      expect(message.preview_text).to eq("Fix the aqueduct.")
    end

    it "extracts text from canonical content-blocks assistant messages" do
      message = described_class.new(chat_session: session, role: "assistant", content: [
        { "type" => "thinking", "thinking" => "Consider the plan." },
        { "type" => "text", "text" => "Here is the answer." }
      ])

      expect(message.preview_text).to eq("Here is the answer.")
    end

    it "collapses newlines and repeated whitespace into single spaces" do
      message = described_class.new(chat_session: session, role: "user", content: { "text" => "Line one.\n\n  Line   two." })

      expect(message.preview_text).to eq("Line one. Line two.")
    end

    it "truncates long text to the byte cap without splitting a UTF-8 character" do
      message = described_class.new(chat_session: session, role: "user", content: { "text" => "a" * 600 })

      expect(message.preview_text.bytesize).to eq(described_class::PREVIEW_TEXT_MAX_BYTES)
    end
  end

  describe "#turn_in_flight?" do
    it "flips to false once a non-user message follows the latest user message" do
      session
      described_class.create!(chat_session: session, role: "user", content: { "text" => "What's up?" })

      expect(session.turn_in_flight?).to be true

      described_class.create!(chat_session: session, role: "assistant", content: { "text" => "Hello." })

      expect(session.reload.turn_in_flight?).to be false
    end
  end

  describe "after_create_commit :broadcast_app_event" do
    it "does not ask Rails to server-render chat controls for message updates" do
      allow(AppEvents).to receive(:broadcast)
      expect(session).not_to receive(:broadcast_controls)

      described_class.create!(chat_session: session, role: "user", content: { "text" => "Hi" })
    end

    it "broadcasts a typed replace-tail payload for React chat rendering" do
      described_class.create!(chat_session: session, role: "user", content: { "text" => "Hi" })
      expect(session).not_to receive(:broadcast_controls)

      expect(AppEvents).to receive(:broadcast) do |user:, type:, resource:, id:, changed:, payload:|
        expect(user).to eq(session.user)
        expect(type).to eq("updated")
        expect(resource).to eq("chat")
        expect(id).to eq(session.id)
        expect(changed).to eq([ "messages" ])
        expect(payload).to include(action: "replace_tail", turn_in_flight: false, agent_busy: false)
        expect(payload[:replace_from_id]).to be_present
        expect(payload[:messages].last).to include(
          type: "message",
          role: "assistant",
          content: { "text" => "Hello from React." },
          text: "Hello from React."
        )
        expect(payload.to_s).not_to include("html")
      end

      described_class.create!(chat_session: session, role: "assistant", content: { "text" => "Hello from React." })
    end

    it "falls back to invalidating messages when the realtime tail payload cannot be loaded" do
      allow_any_instance_of(described_class).to receive(:realtime_tail_payload).and_return(nil)

      expect(AppEvents).to receive(:broadcast) do |user:, type:, resource:, id:, changed:, payload:|
        expect(user).to eq(session.user)
        expect(type).to eq("updated")
        expect(resource).to eq("chat")
        expect(id).to eq(session.id)
        expect(changed).to eq([ "messages" ])
        expect(payload).to include(
          action: "invalidate_messages",
          reason: "tail_payload_too_large",
          turn_in_flight: false,
          agent_busy: false
        )
      end

      expect {
        described_class.create!(chat_session: session, role: "assistant", content: { "text" => "Hello from fallback." })
      }.not_to raise_error
    end
  end

  describe "#canonical_content_format?" do
    it "returns true for assistant messages with content-blocks array" do
      message = described_class.new(chat_session: session, role: "assistant",
                                    content: [ { "type" => "text", "text" => "Hi" } ])
      expect(message.canonical_content_format?).to be true
    end

    it "returns false for legacy assistant messages with flat text hash" do
      message = described_class.new(chat_session: session, role: "assistant",
                                    content: { "text" => "Hi" })
      expect(message.canonical_content_format?).to be false
    end

    it "returns true for tool_use messages with type key in content" do
      message = described_class.new(chat_session: session, role: "tool_use",
                                    content: { "type" => "tool_use", "id" => "t1", "name" => "Read", "input" => {} })
      expect(message.canonical_content_format?).to be true
    end

    it "returns false for legacy tool_use messages with input key" do
      message = described_class.new(chat_session: session, role: "tool_use",
                                    content: { "input" => { "file_path" => "/x" } })
      expect(message.canonical_content_format?).to be false
    end

    it "returns true for tool_result messages with type key in content" do
      message = described_class.new(chat_session: session, role: "tool_result",
                                    content: { "type" => "tool_result", "tool_use_id" => "t1", "content" => "ok", "is_error" => false })
      expect(message.canonical_content_format?).to be true
    end

    it "returns false for legacy tool_result messages with result key" do
      message = described_class.new(chat_session: session, role: "tool_result",
                                    content: { "result" => "ok", "is_error" => false })
      expect(message.canonical_content_format?).to be false
    end

    it "returns true for user and system messages (format unchanged)" do
      user_msg = described_class.new(chat_session: session, role: "user", content: { "text" => "Hi" })
      system_msg = described_class.new(chat_session: session, role: "system", content: { "text" => "Info" })
      expect(user_msg.canonical_content_format?).to be true
      expect(system_msg.canonical_content_format?).to be true
    end
  end

  describe "after_create_commit :enqueue_search_index" do
    it "enqueues search indexing for user content" do
      allow(AppEvents).to receive(:broadcast)

      expect {
        described_class.create!(chat_session: session, role: "user", content: { "text" => "Find me." })
      }.to have_enqueued_job(IndexChatMessageJob).with(kind_of(Integer)).on_queue("indexing")
    end

    it "does not enqueue search indexing for tool-only messages" do
      allow(AppEvents).to receive(:broadcast)

      expect {
        described_class.create!(chat_session: session, role: "tool_use", content: { "name" => "inspect_repo" })
      }.not_to have_enqueued_job(IndexChatMessageJob)
    end
  end

  describe "after_create_commit :clear_suggested_next_step" do
    it "clears the stored suggestion when a user message lands" do
      allow(AppEvents).to receive(:broadcast)
      session.update!(suggested_next_step: "Create an Epic from these findings")

      described_class.create!(chat_session: session, role: "user", content: { "text" => "Actually, let's refactor first." })

      expect(session.reload.suggested_next_step).to be_nil
    end

    it "keeps the stored suggestion for non-user messages" do
      allow(AppEvents).to receive(:broadcast)
      session.update!(suggested_next_step: "Create an Epic from these findings")

      described_class.create!(chat_session: session, role: "assistant", content: { "text" => "Done." })

      expect(session.reload.suggested_next_step).to eq("Create an Epic from these findings")
    end
  end

  describe "#sender" do
    let(:sender) { Factories.user }

    it "returns the sender_user for user-role messages" do
      message = described_class.create!(
        chat_session: session,
        role: "user",
        content: { "text" => "Hello" },
        sender_user: sender
      )

      expect(message.sender).to eq(sender)
    end

    it "returns nil for non-user-role messages even if sender_user is set" do
      message = described_class.create!(
        chat_session: session,
        role: "assistant",
        content: { "text" => "Hello" },
        sender_user: sender
      )

      expect(message.sender).to be_nil
    end

    it "returns nil for user-role messages without a sender_user" do
      message = described_class.create!(
        chat_session: session,
        role: "user",
        content: { "text" => "Hello" }
      )

      expect(message.sender).to be_nil
    end
  end

  it "fans out broadcast_app_event to all session participants" do
    other_user = Factories.user
    session.chat_participants.create!(user: other_user, role: "member")

    allow(AppEvents).to receive(:broadcast)

    described_class.create!(chat_session: session, role: "user", content: { "text" => "Hello" })

    expect(AppEvents).to have_received(:broadcast).with(hash_including(user: session.user))
    expect(AppEvents).to have_received(:broadcast).with(hash_including(user: other_user))
  end

  describe "soft deletion" do
    let(:actor) { Factories.user }

    describe ".active and .deleted scopes" do
      it "returns only non-deleted messages from .active and only deleted messages from .deleted" do
        active_message = described_class.create!(chat_session: session, role: "user", content: { "text" => "Kept" })
        deleted_message = described_class.create!(chat_session: session, role: "user", content: { "text" => "Gone" })
        deleted_message.soft_delete_by!(actor)

        expect(described_class.active).to include(active_message)
        expect(described_class.active).not_to include(deleted_message)
        expect(described_class.deleted).to include(deleted_message)
        expect(described_class.deleted).not_to include(active_message)
      end
    end

    describe "#soft_delete_by!" do
      it "sets deleted_at and deleted_by_user for a User actor" do
        message = described_class.create!(chat_session: session, role: "user", content: { "text" => "Hi" })

        message.soft_delete_by!(actor)

        expect(message).to be_deleted
        expect(message.deleted_at).to be_present
        expect(message.deleted_by_user).to eq(actor)
      end

      it "sets deleted_at without deleted_by_user for a non-User actor" do
        message = described_class.create!(chat_session: session, role: "user", content: { "text" => "Hi" })
        run = Factories.job.initial_run

        message.soft_delete_by!(run)

        expect(message).to be_deleted
        expect(message.deleted_by_user).to be_nil
      end
    end

    describe "#deleted?" do
      it "is false for a message with no deleted_at" do
        message = described_class.create!(chat_session: session, role: "user", content: { "text" => "Hi" })

        expect(message.deleted?).to be false
      end

      it "is true once soft-deleted" do
        message = described_class.create!(chat_session: session, role: "user", content: { "text" => "Hi" })
        message.soft_delete_by!(actor)

        expect(message.deleted?).to be true
      end
    end
  end

  describe "after_create_commit :deliver_to_platform" do
    let(:platform_session) do
      ChatSession.create!(user: repo.user, origin_platform: "telegram", trigger_policy: "speak_when_spoken_to")
    end

    it "is a no-op for non-platform sessions" do
      expect(PlatformDelivery::Registry).not_to receive(:for)

      allow(AppEvents).to receive(:broadcast)
      described_class.create!(chat_session: session, role: "assistant", content: { "text" => "Hi" })
    end

    it "is a no-op for user-role messages even in platform sessions" do
      expect(PlatformDelivery::Registry).not_to receive(:for)

      allow(AppEvents).to receive(:broadcast)
      described_class.create!(chat_session: platform_session, role: "user", content: { "text" => "Hi" })
    end

    it "does not raise or deliver when no adapter is registered for the platform" do
      Factories.platform_identity(user: repo.user, platform: "telegram")
      allow(AppEvents).to receive(:broadcast)

      expect {
        described_class.create!(chat_session: platform_session, role: "assistant", content: { "text" => "Hello" })
      }.not_to raise_error
    end

    it "calls deliver on the adapter for each participant with a matching identity" do
      other_user = Factories.user
      platform_session.chat_participants.create!(user: other_user, role: "member")

      identity = Factories.platform_identity(user: repo.user, platform: "telegram")
      adapter = instance_double(PlatformDelivery::WebAdapter, deliver: nil)
      allow(PlatformDelivery::Registry).to receive(:registered?).with("telegram").and_return(true)
      allow(PlatformDelivery::Registry).to receive(:for).with("telegram").and_return(adapter)
      allow(AppEvents).to receive(:broadcast)

      msg = described_class.create!(chat_session: platform_session, role: "assistant", content: { "text" => "Hello" })

      expect(adapter).to have_received(:deliver).with(message: msg, platform_identity: identity)
    end

    it "skips participants without a matching PlatformIdentity" do
      participant_without_identity = Factories.user
      platform_session.chat_participants.create!(user: participant_without_identity, role: "member")

      adapter = instance_double(PlatformDelivery::BaseAdapter, deliver: nil)
      allow(PlatformDelivery::Registry).to receive(:registered?).with("telegram").and_return(true)
      allow(PlatformDelivery::Registry).to receive(:for).with("telegram").and_return(adapter)
      allow(AppEvents).to receive(:broadcast)

      described_class.create!(chat_session: platform_session, role: "assistant", content: { "text" => "Hello" })

      expect(adapter).not_to have_received(:deliver)
    end
  end
end
