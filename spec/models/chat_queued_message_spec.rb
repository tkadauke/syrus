require "rails_helper"

RSpec.describe ChatQueuedMessage, type: :model do
  it "requires queued text content" do
    chat = ChatSession.create!(user: Factories.user)
    message = described_class.new(chat_session: chat, content: { "text" => "   " })

    expect(message).not_to be_valid
    expect(message.errors[:content]).to include("can't be blank")
  end

  it "is valid with blank text when it carries a walkthrough video" do
    chat = ChatSession.create!(user: Factories.user)
    message = described_class.new(chat_session: chat, content: { "text" => "", "video_walkthrough_id" => 42 })

    expect(message).to be_valid
  end

  it "is valid with blank text when it carries file/image attachments" do
    chat = ChatSession.create!(user: Factories.user)
    message = described_class.new(
      chat_session: chat,
      content: { "text" => "", "attachments" => [ { "mime_type" => "image/png", "data" => "x" } ] }
    )

    expect(message).to be_valid
  end

  it "normalizes draft content" do
    chat = ChatSession.create!(user: Factories.user)
    message = described_class.new(
      chat_session: chat,
      content: { "text" => "Inspect this", "attachments" => [ { "name" => "shot.png", "mime_type" => "image/png", "data" => "abc" } ] }
    )

    expect(message.text).to eq("Inspect this")
    expect(message.draft_content.attachments).to contain_exactly(include("name" => "shot.png", "mime_type" => "image/png", "data" => "abc"))
  end
end
