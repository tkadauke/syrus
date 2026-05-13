require "rails_helper"

RSpec.describe ChatPendingAction do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def adhoc_job(**attrs)
    Job.create!({
      user: user,
      repository: repository,
      kind: "adhoc",
      issue_number: nil,
      issue_title: "Manual job",
      issue_body: "Do the thing."
    }.merge(attrs))
  end

  it "confirms an add_repo_note action once" do
    action = chat_session.pending_actions.create!(
      action: "add_repo_note",
      payload: { "body" => "Default branch is trunk." }
    )

    expect(action.confirm!).to be true
    expect(action.reload).to be_confirmed
    expect(repository.repository_notes.active.pluck(:body)).to eq([ "Default branch is trunk." ])

    expect(action.confirm!).to be false
    expect(repository.repository_notes.active.count).to eq(1)
  end

  it "confirms a remove_repo_note action" do
    note = repository.repository_notes.create!(body: "Short-lived.", author: "operator")
    action = chat_session.pending_actions.create!(
      action: "remove_repo_note",
      payload: { "id" => note.id }
    )

    expect(action.confirm!).to be true
    expect(note.reload).to be_removed
  end

  it "can reject a pending action without applying it" do
    action = chat_session.pending_actions.create!(
      action: "add_repo_note",
      payload: { "body" => "Do not pin this." }
    )

    expect(action.reject!).to be true
    expect(action.reload).to be_rejected
    expect(repository.repository_notes).to be_empty
  end

  it "validates job-control payloads include a job_id" do
    %w[cancel_job retry_job rebase_job].each do |action_name|
      action = chat_session.pending_actions.build(action: action_name, payload: {})

      expect(action).not_to be_valid
      expect(action.errors[:payload]).to include("job_id is required")
    end
  end

  it "confirms a cancel_job action by closing the Job and cancelling active Runs" do
    job = Factories.job(repository: repository)
    run = job.current_run
    action = chat_session.pending_actions.create!(
      action: "cancel_job",
      payload: { "job_id" => job.id }
    )

    expect(action.confirm!).to be true

    expect(job.reload).to be_closed
    expect(job.closure_reason).to eq("cancelled")
    expect(run.reload).to be_cancelled
  end

  it "confirms a retry_job action by starting a retry Workflow" do
    job = adhoc_job
    Workflows::Initial.instantiate(job: job).update!(state: "succeeded")
    action = chat_session.pending_actions.create!(
      action: "retry_job",
      payload: { "job_id" => job.id }
    )

    expect {
      expect(action.confirm!).to be true
    }.to change { job.workflows.where(trigger_kind: "retry").count }.by(1)

    workflow = job.workflows.where(trigger_kind: "retry").last
    expect(workflow.first_step.runs.count).to eq(1)
  end

  it "confirms a rebase_job action by starting a rebase Workflow" do
    job = adhoc_job(pr_number: 17)
    action = chat_session.pending_actions.create!(
      action: "rebase_job",
      payload: { "job_id" => job.id }
    )

    expect {
      expect(action.confirm!).to be true
    }.to change { job.workflows.where(trigger_kind: "rebase").count }.by(1)

    workflow = job.workflows.where(trigger_kind: "rebase").last
    expect(workflow.first_step.runs.count).to eq(1)
  end

  it "does not confirm a stale rejected action" do
    job = adhoc_job
    action = chat_session.pending_actions.create!(
      action: "cancel_job",
      payload: { "job_id" => job.id }
    )
    action.reject!

    expect(action.confirm!).to be false
    expect(job.reload).to be_open
  end

  def pending_action(**payload)
    described_class.create!(
      user: user,
      repository: repository,
      chat_session: chat_session,
      action_type: "schedule_recurring",
      payload: {
        "cron_expression" => "0 9 * * *",
        "label" => "Daily review",
        "prompt" => "Review the project."
      }.merge(payload)
    )
  end

  it "confirms a schedule_recurring action into a RecurringTask" do
    action = pending_action

    expect {
      action.confirm!(user: user)
    }.to change { RecurringTask.count }.by(1)

    task = RecurringTask.last
    expect(task).to have_attributes(
      user: user,
      repository: repository,
      label: "Daily review",
      prompt: "Review the project.",
      cron_expression: "0 9 * * *"
    )
    expect(action.reload).to be_confirmed
    expect(action.result).to eq(task)
  end

  it "does not create the RecurringTask before confirmation" do
    pending_action

    expect(RecurringTask.count).to eq(0)
  end

  it "rejects mismatched repository and chat session" do
    other_repo = Factories.repository(user: user)
    action = described_class.new(
      user: user,
      repository: other_repo,
      chat_session: chat_session,
      action_type: "schedule_recurring",
      payload: { "cron_expression" => "0 9 * * *", "label" => "x", "prompt" => "y" }
    )

    expect(action).not_to be_valid
    expect(action.errors[:repository]).to be_present
  end
end
