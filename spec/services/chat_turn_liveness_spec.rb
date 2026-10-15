require "rails_helper"

RSpec.describe ChatTurnLiveness do
  it "uses the latest active user message" do
    chat = ChatSession.create!(user: Factories.user)
    active_message = chat.messages.create!(role: "user", content: { "text" => "active" })
    chat.messages.create!(role: "user", content: { "text" => "retracted" }, deleted_at: Time.current)

    expect(described_class.new(chat).latest_user_message).to eq(active_message)
  end
end
