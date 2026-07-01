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
      }.to have_enqueued_job(IndexChatMessageJob).with(kind_of(Integer)).on_queue("default")
    end

    it "does not enqueue search indexing for tool-only messages" do
      allow(AppEvents).to receive(:broadcast)

      expect {
        described_class.create!(chat_session: session, role: "tool_use", content: { "name" => "inspect_repo" })
      }.not_to have_enqueued_job(IndexChatMessageJob)
    end
  end
end
