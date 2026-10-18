require "rails_helper"

RSpec.describe ChatTurnLiveness do
  it "uses the latest active user message" do
    chat = ChatSession.create!(user: Factories.user)
    active_message = chat.messages.create!(role: "user", content: { "text" => "active" })
    chat.messages.create!(role: "user", content: { "text" => "retracted" }, deleted_at: Time.current)

    expect(described_class.new(chat).latest_user_message).to eq(active_message)
  end

  it "returns the failed execution error for this chat turn" do
    chat = ChatSession.create!(user: Factories.user)
    message = chat.messages.create!(role: "user", content: { "text" => "active" })
    liveness = described_class.new(chat)
    # Solid Queue tables are not part of the normal single-database test schema,
    # so stub the queue query while exercising argument matching and decoding.
    allow(liveness).to receive(:failed_chat_turn_job_rows).with(created_after: message.created_at).and_return([
      [ { "arguments" => [ chat.id + 1, message.id ] }, { "exception_class" => "OtherError" } ],
      [ { "arguments" => [ chat.id, message.id ] }, '{"exception_class":"SolidQueue::Processes::ProcessPrunedError"}' ]
    ])

    expect(liveness.failed_chat_turn_job_error).to eq(
      "exception_class" => "SolidQueue::Processes::ProcessPrunedError"
    )
  end
end
