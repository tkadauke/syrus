require "rails_helper"

RSpec.describe ChatJobSummary do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat) { ChatSession.create!(user: user, repository: repository, last_message_at: Time.current) }

  def summary
    described_class.for(chat_sessions: [ chat ], user: user).fetch(chat.id)
  end

  def proposal_for(job)
    ChatProposal.create!(
      chat_session: chat,
      repository: repository,
      job: job,
      kind: "job",
      state: "confirmed",
      slug: "job-#{job.id}",
      title: "Job #{job.id}",
      body: "Implement it.",
      provider_setting: "default"
    )
  end

  it "associates confirmed proposal Jobs and only a Job's earliest active discussion chat" do
    proposed_job = Factories.job_record(user: user, repository: repository)
    discussion_job = Factories.job_record(user: user, repository: repository)
    later_chat = ChatSession.create!(user: user, repository: repository)
    proposal_for(proposed_job)
    ChatAttachment.create!(chat_session: chat, attachable: discussion_job, attached_at: 2.minutes.ago)
    ChatAttachment.create!(chat_session: later_chat, attachable: discussion_job, attached_at: 1.minute.ago)

    expect(summary[:jobs].pluck(:id)).to contain_exactly(proposed_job.id, discussion_job.id)
    expect(described_class.for(chat_sessions: [ later_chat ], user: user).fetch(later_chat.id, { jobs: [] })[:jobs]).to be_empty
  end

  it "counts implementation workflows but excludes landing and CI repair" do
    active = Factories.job_record(user: user, repository: repository, state: "running")
    landing = Factories.job_record(user: user, repository: repository, state: "landing")
    repair = Factories.job_record(user: user, repository: repository, state: "running")
    [ active, landing, repair ].each { |job| proposal_for(job) }
    Workflow.create!(job: active, trigger_kind: "initial", state: "running", started_at: 3.minutes.ago)
    Workflow.create!(job: landing, trigger_kind: "auto_merge", state: "running", started_at: 2.minutes.ago)
    Workflow.create!(job: repair, trigger_kind: "ci_failure", state: "queued")

    expect(summary[:active_count]).to eq(1)
    expect(summary[:jobs].index_by { |row| row[:id] }.fetch(active.id)[:group]).to eq("running")
    expect(summary[:jobs].index_by { |row| row[:id] }.values_at(landing.id, repair.id).pluck(:group)).to eq([ "ready", nil ])
  end

  it "keeps a terminal failure running while an automatic retry is pending" do
    job = Factories.job_record(user: user, repository: repository, state: "failed")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "failed", finished_at: Time.current)
    proposal_for(job)
    AutoRetryAttempt.create!(job: job, workflow: workflow, agent_provider: "codex", failure_classification: "transient", retry_kind: "retry_workflow", attempt_number: 1, scheduled_at: 5.minutes.from_now)

    expect(summary).to include(active_count: 1, outcome: nil)
    expect(summary[:jobs].first[:group]).to eq("running")
  end

  it "shows the worst unread outcome and clears outcomes read after completion" do
    ready = Factories.job_record(user: user, repository: repository, state: "implemented", updated_at: 1.minute.ago)
    failed = Factories.job_record(user: user, repository: repository, state: "failed", updated_at: Time.current)
    proposal_for(ready)
    proposal_for(failed)
    participant = chat.chat_participants.find_by!(user: user)
    participant.update_columns(last_read_at: 2.minutes.ago)

    expect(summary[:outcome]).to eq("failed")
    participant.update_columns(last_read_at: 1.minute.from_now)
    expect(summary[:outcome]).to be_nil
  end

  it "includes aggregate Epic progress on each Job row" do
    epic = Factories.epic(user: user, repository: repository)
    job = Factories.job_record(user: user, repository: repository, epic: epic, state: "running")
    Factories.job_record(user: user, repository: repository, epic: epic, state: "implemented", issue_number: 43)
    proposal_for(job)
    Workflow.create!(job: job, trigger_kind: "initial", state: "queued")

    expect(summary[:jobs].first[:epic]).to include(slug: epic.slug, completed: 1, total: 2)
  end
end
