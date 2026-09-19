require "rails_helper"

RSpec.describe App::ChatTurnRetryState do
  let(:user) { Factories.user }
  let(:chat) { ChatSession.create!(user: user, turn_in_flight: true, last_message_at: Time.current) }
  let(:root_message) do
    chat.messages.create!(
      role: "user",
      content: { "text" => "Please keep going." },
      sender_user_id: user.id
    )
  end

  it "returns nil when the chat turn has no auto-retry state" do
    expect(described_class.for(chat)).to be_nil
  end

  it "describes the pending backoff attempt for the current turn" do
    scheduled_at = Time.zone.parse("2026-09-18 12:05:00 UTC")
    ChatTurnAutoRetryAttempt.create!(
      chat_session: chat,
      root_user_message: root_message,
      user_message: root_message,
      attempt_number: 2,
      scheduled_at: scheduled_at
    )

    travel_to(Time.zone.parse("2026-09-18 12:00:00 UTC")) do
      expect(described_class.for(chat)).to include(
        classification: "chat_turn_crashed",
        classification_label: "Chat turn crashed",
        retryable: true,
        next_auto_retry_at: scheduled_at.iso8601,
        retry_attempt_count: 2,
        retry_budget_remaining: ChatTurnAutoRetryAttempt::MAX_ATTEMPTS - 2,
        retry_budget: ChatTurnAutoRetryAttempt::MAX_ATTEMPTS,
        auto_retry_exhausted: false,
        provider_circuit_open: false,
        retry_delayed_until: nil,
        retry_delay_reason: nil,
        state_label: "Retry scheduled"
      )
    end
  end

  it "returns nil after the retry budget exhausts and the turn is no longer in flight" do
    exhausted_at = Time.zone.parse("2026-09-18 12:00:00 UTC")
    ChatTurnAutoRetryAttempt.create!(
      chat_session: chat,
      root_user_message: root_message,
      user_message: root_message,
      attempt_number: ChatTurnAutoRetryAttempt::MAX_ATTEMPTS,
      scheduled_at: 1.minute.ago,
      exhausted_at: exhausted_at
    )
    chat.update!(turn_in_flight: false)

    expect(described_class.for(chat)).to be_nil
  end
end
