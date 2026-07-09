require "rails_helper"

RSpec.describe ChatScratchpadItem, type: :model do
  it "requires content" do
    chat = ChatSession.create!(user: Factories.user)
    item = described_class.new(chat_session: chat, content: "   ", position: 0)

    expect(item).not_to be_valid
    expect(item.errors[:content]).to include("can't be blank")
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
