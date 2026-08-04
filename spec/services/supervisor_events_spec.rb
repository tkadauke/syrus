require "rails_helper"

RSpec.describe SupervisorEvents, type: :service do
  include ActiveJob::TestHelper

  let!(:feature) do
    Feature.find_or_create_by!(slug: "admin_supervisor_chat") do |record|
      record.category = "Operations"
      record.name = "Admin supervisor chat"
      record.enabled = false
    end
  end
  let!(:admin) { Factories.user(admin: true) }
  let!(:other_admin) { Factories.user(admin: true) }
  let!(:non_admin) { Factories.user(admin: false) }
  let(:repository) { Factories.repository(user: admin) }

  before do
    feature.update!(enabled: false)
    Feature.clear_enabled_cache!("admin_supervisor_chat")
    clear_enqueued_jobs
    allow(AppEvents).to receive(:broadcast)
  end

  def enable_supervisor_chat!
    feature.update!(enabled: true)
    Feature.clear_enabled_cache!("admin_supervisor_chat")
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

  it "no-ops while admin_supervisor_chat is disabled" do
    result = nil
    expect {
      result = described_class.publish!(
        kind: "job_failed",
        severity: "critical",
        subject: "Job failed",
        repository: repository,
        actor: admin,
        summary: "JOB-1 failed",
        details: { "job_id" => 1 },
        dedupe_key: "job_failed:1"
      )
    }.not_to change(ChatMessage, :count)
    expect(result).to eq([])
    expect(ChatScopedEvent.count).to eq(0)

    expect(ChatSession.where(system_kind: "supervisor")).to be_empty
  end

  it "creates scoped events and evaluator jobs for every admin supervisor chat" do
    enable_supervisor_chat!
    job = Factories.job_record(user: admin, repository: repository, issue_number: 12, issue_title: "Repair main")

    events = described_class.publish!(
      kind: "main_broken",
      severity: "critical",
      subject: "Main branch broken",
      repository: repository,
      job: job,
      actor: admin,
      summary: "CI failed at abc123",
      details: { "sha" => "abc123" },
      dedupe_key: "main_broken:#{repository.id}:abc123"
    )

    expect(events.size).to eq(2)
    expect(ChatScopedEvent.count).to eq(2)
    expect(non_admin.chat_sessions.where(system_kind: "supervisor")).to be_empty

    chat = admin.chat_sessions.find_by!(system_kind: "supervisor")
    scoped_event = ChatScopedEvent.find_by!(chat_session: chat)
    expect(scoped_event).to have_attributes(
      source_kind: "main_broken",
      delivery_state: "pending",
      dedupe_key: "main_broken:#{repository.id}:abc123",
      repository_id: repository.id,
      job_id: job.id,
      chat_message_id: nil
    )
    expect(scoped_event.delivered_at).to be_nil
    expect(scoped_event.payload).to include(
      "kind" => "main_broken",
      "severity" => "critical",
      "summary" => "CI failed at abc123"
    )
    expect(scoped_event.payload["repository"]).to include(
      "id" => repository.id,
      "slug" => repository.slug
    )
    expect(chat.messages.pluck(:role)).to eq([ "user" ])
    expect(chat.messages.first.content).to include(
      "source" => "supervisor_kickoff",
      "text" => include("Supervisor operations triage")
    )
    expect(ChatScopedEventEvaluatorJob).to have_been_enqueued.with(scoped_event.id, chat.id)
  end

  it "dedupes repeated events with the same key in recent supervisor history" do
    enable_supervisor_chat!

    2.times do
      described_class.publish!(
        kind: "main_broken",
        severity: "critical",
        subject: "Main branch broken",
        repository: repository,
        actor: admin,
        summary: "CI failed at abc123",
        dedupe_key: "main_broken:#{repository.id}:abc123"
      )
    end

    expect(admin.chat_sessions.find_by!(system_kind: "supervisor").messages.count).to eq(1)
    expect(other_admin.chat_sessions.find_by!(system_kind: "supervisor").messages.count).to eq(1)
    expect(admin.chat_sessions.find_by!(system_kind: "supervisor").scoped_events.count).to eq(1)
    expect(other_admin.chat_sessions.find_by!(system_kind: "supervisor").scoped_events.count).to eq(1)
  end

  it "enqueues evaluator jobs instead of chat turns for scoped supervisor event delivery" do
    enable_supervisor_chat!
    SupervisorChat.ensure_for!(admin)
    SupervisorChat.ensure_for!(other_admin)
    clear_enqueued_jobs

    expect {
      described_class.publish!(
        kind: "job_failed",
        severity: "critical",
        subject: "Job failed",
        repository: repository,
        actor: admin,
        summary: "The workflow failed.",
        dedupe_key: "job_failed:1"
      )
    }.not_to have_enqueued_job(ChatTurnJob)
    expect(ChatScopedEventEvaluatorJob).to have_been_enqueued.exactly(2).times
  end

  it "marks supervisor chats unread and broadcasts a chat sidebar update" do
    enable_supervisor_chat!
    chat = SupervisorChat.ensure_for!(admin)
    chat.update!(last_message_at: 1.hour.ago, last_read_at: Time.current)

    described_class.publish!(
      kind: "job_implemented",
      severity: "info",
      subject: "Job implemented",
      repository: repository,
      actor: admin,
      summary: "PR opened",
      dedupe_key: "job_implemented:1"
    )

    chat.reload
    expect(chat.last_read_at).to be_nil
    expect(chat.last_message_at).to be > 1.minute.ago
    expect(AppEvents).to have_received(:broadcast).with(
      user: admin,
      type: "updated",
      resource: "chat",
      id: chat.id,
      changed: [ "last_message_at", "last_read_at", "supervisor_event" ]
    )
  end

  it "delivers PR merge events to the ordinary chat that originated the Job" do
    enable_supervisor_chat!
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
    enable_supervisor_chat!
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
    expect(AppEvents).not_to have_received(:broadcast).with(
      user: chat.user,
      type: "updated",
      resource: "chat",
      id: chat.id,
      changed: [ "last_message_at", "last_read_at", "scoped_event" ]
    )
  end

  it "delivers Job failure events from related Runs to the originating ordinary chat" do
    enable_supervisor_chat!
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
    enable_supervisor_chat!
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
    enable_supervisor_chat!
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
end
