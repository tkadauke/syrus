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
end
