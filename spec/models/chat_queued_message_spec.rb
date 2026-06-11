require "rails_helper"

RSpec.describe ChatQueuedMessage, type: :model do
  it "requires queued text content" do
    chat = ChatSession.create!(user: Factories.user)
    message = described_class.new(chat_session: chat, content: { "text" => "   " })

    expect(message).not_to be_valid
    expect(message.errors[:content]).to include("can't be blank")
  end
end
