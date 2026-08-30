require "rails_helper"

RSpec.describe ChatGoalWakeup, type: :service do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, repository: repository) }
  let(:goal) { chat.chat_goals.create!(prompt: "Ship the launch plan") }

  before { clear_enqueued_jobs }

  it "records a deduped scoped event and dispatches one continuation" do
    expect {
      2.times do
        described_class.publish_work_event!(
          goal: goal,
          kind: "job_implemented",
          subject: "Job implemented",
          summary: "JOB-1 implemented.",
          repository: repository,
          work_state: { "state" => "implemented" },
          dedupe_key: "goal:#{goal.id}:job:1:implemented"
        )
      end
    }.to change(ChatScopedEvent, :count).by(1)
      .and change(ChatMessage, :count).by(1)

    message = chat.messages.last
    expect(message.content).to include(
      "source" => "goal_continuation",
      "goal_continuation" => true,
      "chat_goal_id" => goal.id
    )
    expect(ChatTurnJob).to have_been_enqueued.with(chat.id, message.id)
  end

  it "does not enqueue continuation turns for paused or stopped goals" do
    goal.pause!

    described_class.publish_work_event!(
      goal: goal,
      kind: "job_implemented",
      subject: "Job implemented",
      summary: "JOB-1 implemented.",
      repository: repository,
      work_state: { "state" => "implemented" },
      dedupe_key: "goal:#{goal.id}:paused"
    )

    expect(chat.messages).to be_empty
    expect(ChatScopedEvent.where(chat_session: chat)).to be_empty

    goal.resume!
    goal.stop!
    described_class.publish_work_event!(
      goal: goal,
      kind: "job_approved",
      subject: "Job approved",
      summary: "JOB-1 approved.",
      repository: repository,
      work_state: { "state" => "approved" },
      dedupe_key: "goal:#{goal.id}:stopped"
    )

    expect(chat.messages).to be_empty
  end

  it "queues but does not dispatch while a chat turn is active" do
    chat.update!(turn_in_flight: true)

    described_class.publish_work_event!(
      goal: goal,
      kind: "job_implemented",
      subject: "Job implemented",
      summary: "JOB-1 implemented.",
      repository: repository,
      work_state: { "state" => "implemented" },
      dedupe_key: "goal:#{goal.id}:busy"
    )

    expect(chat.chat_queued_messages.pending.count).to eq(1)
    expect(chat.messages).to be_empty
    expect(ChatTurnJob).not_to have_been_enqueued
  end

  it "publishes wakeups from goal-linked Job implementation, approval, and close boundaries" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", chat_goal: goal, issue_number: 12)

    expect {
      job.update!(state: "implemented")
      job.update!(state: "approved")
      job.update!(state: "closed", closure_reason: "pr_merged")
    }.to change(ChatScopedEvent.where(chat_session: chat), :count).by(3)
  end

  it "publishes wakeups when a goal-linked Epic completes" do
    epic = Factories.epic(user: user, repository: repository, state: "in_progress", chat_goal: goal)

    expect {
      epic.update!(state: "done", done_at: Time.current)
    }.to change(ChatScopedEvent.where(chat_session: chat), :count).by(1)

    expect(chat.scoped_events.last.source_kind).to eq("goal_epic_completed")
  end
end
