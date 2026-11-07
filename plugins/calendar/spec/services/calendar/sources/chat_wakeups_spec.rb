require "rails_helper"

RSpec.describe Calendar::Sources::ChatWakeups do
  it "returns only pending wakeups owned by the querying user in the range" do
    user = Factories.user
    other = Factories.user
    chat = ChatSession.create!(user:)
    other_chat = ChatSession.create!(user: other)
    starts_at = 1.hour.ago
    owned = ChatWakeup.create!(user:, chat_session: chat, prompt: "Review the release", fire_at: 1.hour.from_now)
    ChatWakeup.create!(user: other, chat_session: other_chat, prompt: "Private", fire_at: 1.hour.from_now)
    ChatWakeup.create!(user:, chat_session: chat, prompt: "Later", fire_at: 2.weeks.from_now)

    events = described_class.calendar_events(user:, starts_at:, ends_at: 1.day.from_now)

    expect(events.map(&:id)).to eq([ "wakeup-#{owned.id}" ])
    expect(events.first.destination_path).to eq("/chats/#{chat.id}")
  end
end
