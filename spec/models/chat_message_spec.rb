require "rails_helper"

RSpec.describe ChatMessage do
  let(:repo) { Factories.repository }
  let(:session) { ChatSession.create!(repository: repo, user: repo.user) }

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

  # Regression: before this fix the compose form was rendered once
  # (server-side, with turn_in_flight: true) and never refreshed when
  # the turn ended, leaving the Send button disabled until the operator
  # reloaded the page. Every new ChatMessage row now re-broadcasts the
  # compose partial so its `disabled` state tracks `turn_in_flight?`.
  describe "after_create_commit :broadcast_controls_update" do
    it "calls broadcast_controls on the chat session when a message is created" do
      expect(session).to receive(:broadcast_controls)
      described_class.create!(chat_session: session, role: "user", content: { "text" => "Hi" })
    end

    it "flips turn_in_flight? to false once a non-user message follows the latest user message" do
      session
      described_class.create!(chat_session: session, role: "user", content: { "text" => "What's up?" })

      expect(session.turn_in_flight?).to be true

      described_class.create!(chat_session: session, role: "assistant", content: { "text" => "Hello." })

      expect(session.reload.turn_in_flight?).to be false
    end
  end
end
