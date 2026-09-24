require "rails_helper"

RSpec.describe BugReports::ChatStarter do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  # `have_been_enqueued` reads the test adapter's process-wide enqueued_jobs
  # list, which nothing clears between examples. The assertion below was
  # therefore reading whatever an earlier spec in the run had enqueued, and
  # passed only when this file ran on its own.
  before { clear_enqueued_jobs }

  it "does not leave an existing group chat turn in flight when the prompt does not trigger the agent" do
    chat_session = ChatSession.create!(
      user: user,
      repository: repository,
      conversation_kind: "group",
      last_message_at: Time.current
    )
    chat_session.chat_participants.create!(user: Factories.user, role: "member")
    allow(ChatSession).to receive(:create!).and_return(chat_session)

    result = nil
    expect {
      result = described_class.new(user: user, repository: repository).call(
        title: "Group chat bug",
        description: "Record this without waking the agent."
      )
    }.to change(ChatMessage, :count).by(1)
      .and have_enqueued_job(ChatTitleJob)

    expect(result).to be_success
    expect(chat_session.reload).not_to be_turn_in_flight
    expect(ChatTurnJob).not_to have_been_enqueued
  end
end
