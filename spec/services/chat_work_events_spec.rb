require "rails_helper"

RSpec.describe ChatWorkEvents, type: :service do
  include ActiveJob::TestHelper

  let!(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }

  before do
    clear_enqueued_jobs
    allow(AppEvents).to receive(:broadcast)
  end

  def chat_proposal(chat_session:, slug:, title:, job: nil, epic: nil, kind: "job")
    ChatProposal.create!(
      chat_session: chat_session,
      repository: chat_session.repository,
      slug: slug,
      title: title,
      body: "Body for #{title}",
      kind: kind,
      state: "confirmed",
      job: job,
      epic: epic,
      confirmed_at: Time.current,
      filed_at: Time.current
    )
  end

  it "delivers PR merge events to the ordinary chat that originated the Job" do
    chat = ChatSession.create!(user: admin, repository: repository)
    other_chat = ChatSession.create!(user: admin, repository: repository)
    job = Factories.job_record(user: admin, repository: repository, issue_number: 45, pr_number: 17)
    chat_proposal(chat_session: chat, slug: "merge-job", title: "Merge job", job: job)

    described_class.publish!(
      kind: "pr_merged",
      severity: "info",
      subject: "PR merged",
      repository: repository,
      summary: "PR #17 merged.",
      details: { "pr_number" => 17 },
      dedupe_key: "pr_merged:#{repository.id}:17"
    )

    scoped_event = chat.scoped_events.find_by!(source_kind: "pr_merged")
    expect(scoped_event).to have_attributes(job_id: job.id, repository_id: repository.id)
    expect(other_chat.scoped_events).to be_empty
    expect(ChatScopedEventEvaluatorJob).to have_been_enqueued.with(scoped_event.id, chat.id)
  end

  it "does not mark ordinary scoped-event recipients active before evaluator wakeup" do
    chat = ChatSession.create!(
      user: admin,
      repository: repository,
      last_message_at: 1.hour.ago,
      last_read_at: Time.current
    )
    original_last_message_at = chat.last_message_at
    original_last_read_at = chat.last_read_at
    job = Factories.job_record(user: admin, repository: repository, issue_number: 45, pr_number: 17)
    chat_proposal(chat_session: chat, slug: "merge-job", title: "Merge job", job: job)

    described_class.publish!(
      kind: "pr_merged",
      severity: "info",
      subject: "PR merged",
      repository: repository,
      summary: "PR #17 merged.",
      details: { "pr_number" => 17 },
      dedupe_key: "pr_merged:#{repository.id}:17"
    )

    expect(chat.scoped_events.find_by!(source_kind: "pr_merged")).to be_pending
    expect(chat.reload).to have_attributes(
      last_message_at: original_last_message_at,
      last_read_at: original_last_read_at
    )
    expect(AppEvents).not_to have_received(:broadcast)
  end

  it "delivers Job failure events from related Runs to the originating ordinary chat" do
    chat = ChatSession.create!(user: admin, repository: repository)
    job = Factories.job_record(user: admin, repository: repository, issue_number: 46)
    run = Factories.run(job: job, user: admin, agent_provider: "claude", trigger_kind: "initial")
    chat_proposal(chat_session: chat, slug: "failed-job", title: "Failed job", job: job)

    described_class.publish!(
      kind: "job_failed",
      severity: "critical",
      subject: "Job failed",
      repository: repository,
      run: run,
      summary: "The implement run failed.",
      dedupe_key: "job_failed:run:#{run.id}"
    )

    scoped_event = chat.scoped_events.find_by!(source_kind: "job_failed")
    expect(scoped_event).to have_attributes(job_id: job.id, repository_id: repository.id)
    expect(ChatScopedEventEvaluatorJob).to have_been_enqueued.with(scoped_event.id, chat.id)
  end

  it "delivers Epic completion events to the ordinary chat that originated the Epic" do
    chat = ChatSession.create!(user: admin, repository: repository)
    epic = Factories.epic(user: admin, repository: repository, title: "Scoped Epic")
    chat_proposal(chat_session: chat, slug: "scoped-epic", title: "Scoped Epic", epic: epic, kind: "epic")

    described_class.publish!(
      kind: "epic_completed",
      severity: "info",
      subject: "Epic completed",
      repository: repository,
      epic: epic,
      summary: "All child jobs merged.",
      dedupe_key: "epic_completed:#{epic.id}"
    )

    scoped_event = chat.scoped_events.find_by!(source_kind: "epic_completed")
    expect(scoped_event).to have_attributes(epic_id: epic.id, repository_id: repository.id)
    expect(ChatScopedEventEvaluatorJob).to have_been_enqueued.with(scoped_event.id, chat.id)
  end

  it "keeps unrelated Job events out of ordinary chats" do
    chat = ChatSession.create!(user: admin, repository: repository)
    originated_job = Factories.job_record(user: admin, repository: repository, issue_number: 47)
    unrelated_job = Factories.job_record(user: admin, repository: repository, issue_number: 48)
    chat_proposal(chat_session: chat, slug: "originated-job", title: "Originated job", job: originated_job)

    described_class.publish!(
      kind: "job_failed",
      severity: "critical",
      subject: "Job failed",
      repository: repository,
      job: unrelated_job,
      summary: "A different job failed.",
      dedupe_key: "job_failed:#{unrelated_job.id}"
    )

    expect(chat.scoped_events).to be_empty
  end

  it "dedupes repeated events with the same key for the same recipient chat" do
    chat = ChatSession.create!(user: admin, repository: repository)
    job = Factories.job_record(user: admin, repository: repository, issue_number: 49, pr_number: 20)
    chat_proposal(chat_session: chat, slug: "dedupe-job", title: "Dedupe job", job: job)

    2.times do
      described_class.publish!(
        kind: "pr_merged",
        severity: "info",
        subject: "PR merged",
        repository: repository,
        job: job,
        summary: "PR #20 merged.",
        dedupe_key: "pr_merged:#{repository.id}:20"
      )
    end

    expect(chat.scoped_events.count).to eq(1)
  end
end
