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
    Workflow.create!(job: proposed_job, trigger_kind: "initial", state: "running")
    ChatAttachment.create!(chat_session: chat, attachable: discussion_job, attached_at: 2.minutes.ago)
    Workflow.create!(job: discussion_job, trigger_kind: "initial", state: "running")
    ChatAttachment.create!(chat_session: later_chat, attachable: discussion_job, attached_at: 1.minute.ago)

    expect(summary[:jobs].pluck(:id)).to contain_exactly(proposed_job.id, discussion_job.id)
    expect(described_class.for(chat_sessions: [ later_chat ], user: user).fetch(later_chat.id, { jobs: [] })[:jobs]).to be_empty
  end

  # The sidebar reads four workflow columns and two step columns to render a
  # status pill, but used to load whole rows -- including workflows.artifacts,
  # which averages 152KB in production and exceeds 11MB at the tail. That made
  # a chat list cost seconds of transfer and parsing for data it discards.
  it "never loads the artifacts column when summarizing" do
    job = Factories.job_record(user: user, repository: repository, state: "running")
    proposal_for(job)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", state: "running", started_at: 1.minute.ago)
    workflow.update!(artifacts: { "bulky" => "x" * 50_000 })
    Step.create!(workflow: workflow, kind: "implement", state: "running", position: 1)

    selected = []
    counter = ->(_name, _start, _finish, _id, payload) do
      sql = payload[:sql].to_s
      # Quote-agnostic: the test database quotes identifiers differently
      # from production, and matching only backticks silently matched nothing.
      selected << sql if sql.match?(/\bFROM\s+.?workflows.?\b/i) || sql.match?(/\bFROM\s+.?steps.?\b/i)
    end

    row = nil
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { row = summary }

    expect(selected).to be_present
    # The status pill still renders from the narrowed columns.
    expect(row[:jobs].first[:step]).to eq("implement")
    expect(row[:jobs].first[:group]).to eq("running")
    # ...and no query pulled the artifacts column.
    expect(selected.grep(/artifacts/)).to be_empty
    expect(selected.grep(/SELECT\s+.?workflows.?\.\*/i)).to be_empty
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
    expect(summary[:jobs].index_by { |row| row[:id] }.fetch(landing.id)[:group]).to eq("ready")
    expect(summary[:jobs].pluck(:id)).not_to include(repair.id)
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

  it "omits repeated Epic progress from compact Job rows" do
    epic = Factories.epic(user: user, repository: repository, title: "Compact activity")
    job = Factories.job_record(user: user, repository: repository, epic: epic, state: "running")
    Factories.job_record(user: user, repository: repository, epic: epic, state: "implemented", issue_number: 43)
    Factories.job_record(user: user, repository: repository, epic: epic, state: "approved", issue_number: 44)
    Factories.job_record(user: user, repository: repository, epic: epic, state: "blocked_by_epic", issue_number: 45)
    proposal_for(job)
    Workflow.create!(job: job, trigger_kind: "initial", state: "queued")

    expect(summary[:jobs].first).not_to have_key(:epic)
  end
end
