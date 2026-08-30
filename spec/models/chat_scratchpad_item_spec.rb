require "rails_helper"

RSpec.describe ChatScratchpadItem, type: :model do
  it "requires content" do
    chat = ChatSession.create!(user: Factories.user)
    item = described_class.new(chat_session: chat, content: "   ", position: 0)

    expect(item).not_to be_valid
    expect(item.errors[:content]).to include("can't be blank")
  end

  it "allows blank text when stored draft content carries attachments" do
    chat = ChatSession.create!(user: Factories.user)
    item = described_class.new(
      chat_session: chat,
      content: JSON.generate("text" => "", "attachments" => [ { "name" => "shot.png", "mime_type" => "image/png", "data" => "abc" } ]),
      position: 0
    )

    expect(item).to be_valid
    expect(item.text).to eq("")
    expect(item.draft_content.attachments).to contain_exactly(include("name" => "shot.png"))
  end

  it "treats legacy plain-string content as text-only draft content" do
    chat = ChatSession.create!(user: Factories.user)
    item = described_class.new(chat_session: chat, content: "Draft idea", position: 0)

    expect(item.text).to eq("Draft idea")
    expect(item.draft_content.attachments).to eq([])
  end

  it "broadcasts controls after commit" do
    chat = ChatSession.create!(user: Factories.user)
    expect(chat).to receive(:broadcast_controls).once

    described_class.create!(chat_session: chat, content: "Draft idea", position: 0)
  end

  describe ".ordered" do
    it "orders by position then id" do
      chat = ChatSession.create!(user: Factories.user)
      b = described_class.create!(chat_session: chat, content: "B", position: 1)
      a = described_class.create!(chat_session: chat, content: "A", position: 0)
      c = described_class.create!(chat_session: chat, content: "C", position: 1)

      expect(described_class.ordered.to_a).to eq([ a, b, c ])
    end
  end
end
