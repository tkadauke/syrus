require "rails_helper"

RSpec.describe ChatTurnLiveness do
  it "uses the latest active user message" do
    chat = ChatSession.create!(user: Factories.user)
    active_message = chat.messages.create!(role: "user", content: { "text" => "active" })
    chat.messages.create!(role: "user", content: { "text" => "retracted" }, deleted_at: Time.current)

    expect(described_class.new(chat).latest_user_message).to eq(active_message)
  end

  it "matches failed execution errors to multiple chat turns in one queue query" do
    # Solid Queue tables are not part of the normal single-database test schema,
    # so stub the batched queue query while exercising identity matching.
    allow(described_class).to receive(:failed_chat_turn_job_rows).and_return([
      [ { "arguments" => [ 12, 102 ] }, { "exception_class" => "OtherError" } ],
      [ { "arguments" => [ 11, 101 ] }, '{"exception_class":"SolidQueue::Processes::ProcessPrunedError"}' ]
    ])

    expect(described_class.failed_chat_turn_job_errors_for(11 => 101, 12 => 102)).to eq(
      11 => { "exception_class" => "SolidQueue::Processes::ProcessPrunedError" },
      12 => { "exception_class" => "OtherError" }
    )
  end
end
