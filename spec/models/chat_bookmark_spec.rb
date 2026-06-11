require "rails_helper"

RSpec.describe ChatBookmark do
  let(:repo) { Factories.repository }
  let(:session) { ChatSession.create!(repository: repo, user: repo.user) }
  let(:message) { session.messages.create!(role: "assistant", content: { "text" => "Discuss the aqueduct." }) }

  it "creates with valid attributes" do
    bookmark = described_class.create!(
      chat_message: message,
      label: "Aqueduct routing",
      kind: "topic"
    )

    expect(bookmark).to be_persisted
    expect(bookmark.chat_message).to eq(message)
  end

  it "allows each bookmark kind" do
    described_class::KINDS.each do |kind|
      bookmark = described_class.new(chat_message: message, label: "#{kind} label", kind: kind)

      expect(bookmark).to be_valid
    end
  end

  it "requires a chat message" do
    bookmark = described_class.new(label: "Unmoored", kind: "manual")

    expect(bookmark).not_to be_valid
    expect(bookmark.errors[:chat_message]).to be_present
  end

  it "requires a label" do
    bookmark = described_class.new(chat_message: message, kind: "topic")

    expect(bookmark).not_to be_valid
    expect(bookmark.errors[:label]).to be_present
  end

  it "validates kind against the bookmark kinds" do
    bookmark = described_class.new(chat_message: message, label: "Portent", kind: "omen")

    expect(bookmark).not_to be_valid
    expect(bookmark.errors[:kind]).to be_present
  end

  it "supports epic origin bookmarks on the anchored message" do
    bookmark = message.bookmarks.create!(label: "Epic: rebuild the forum", kind: "epic_origin")

    expect(bookmark).to be_epic_origin
    expect(message.bookmarks).to include(bookmark)
  end

  it "can be deleted" do
    bookmark = described_class.create!(chat_message: message, label: "Delete me", kind: "manual")

    expect { bookmark.destroy }.to change(described_class, :count).by(-1)
  end

  it "anchors to the next rendered chat message when attached to a tool row" do
    user_message = session.messages.create!(role: "user", content: { "text" => "Start here." })
    tool_message = session.messages.create!(role: "tool_use", content: { "name" => "set_bookmark" })
    assistant_message = session.messages.create!(role: "assistant", content: { "text" => "Continue here." })
    bookmark = tool_message.bookmarks.create!(label: "Aqueduct ruling", kind: "topic")

    expect(bookmark.anchor_message_id).to eq(assistant_message.id)
    expect(bookmark.anchor_message_id).not_to eq(user_message.id)
  end

  it "broadcasts a typed bookmark payload for cached chat navigation" do
    allow(AppEvents).to receive(:broadcast)
    message

    expect(AppEvents).to receive(:broadcast).with(
      user: repo.user,
      type: "updated",
      resource: "chat",
      id: session.id,
      changed: [ "bookmarks" ],
      payload: {
        action: "upsert_bookmark",
        bookmark: {
          id: kind_of(Integer),
          label: "Fresh aqueduct",
          chat_message_id: message.id,
          anchor_message_id: message.id
        }
      }
    )

    message.bookmarks.create!(label: "Fresh aqueduct", kind: "topic")
  end
end
