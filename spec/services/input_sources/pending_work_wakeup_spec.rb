require "rails_helper"

RSpec.describe InputSources::PendingWorkWakeup do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def open_job
    Factories.job_record(user: user, repository: repository, state: "queued")
  end

  before do
    allow(WorkIntents::JobWakeup).to receive(:call).and_return(false)
  end

  it "does not wake bare queued workflows without WorkUnit ownership" do
    target = open_job
    Workflow.create!(
      job: target,
      user: user,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: "queued"
    )

    described_class.call(repository)

    expect(WorkIntents::JobWakeup).not_to have_received(:call)
  end

  it "wakes jobs with requested job-scoped intents" do
    target = open_job
    unrelated = open_job
    WorkIntent.create!(
      repository: repository,
      kind: "ci_failure",
      state: "requested",
      scope_type: "job",
      scope_id: target.id
    )

    described_class.call(repository)

    expect(WorkIntents::JobWakeup).to have_received(:call).with(have_attributes(id: target.id)).once
    expect(WorkIntents::JobWakeup).not_to have_received(:call).with(have_attributes(id: unrelated.id))
  end

  it "wakes jobs with active work units" do
    target = open_job
    unrelated = open_job
    intent = WorkIntent.create!(
      repository: repository,
      kind: "initial",
      state: "requested",
      scope_type: "job",
      scope_id: target.id
    )
    unit = WorkUnit.create!(
      repository: repository,
      work_intent: intent,
      kind: "initial",
      state: "blocked",
      scope_type: "job",
      scope_id: target.id
    )
    unit.work_unit_members.create!(job: target, role: "primary")

    described_class.call(repository)

    expect(WorkIntents::JobWakeup).to have_received(:call).with(have_attributes(id: target.id)).once
    expect(WorkIntents::JobWakeup).not_to have_received(:call).with(have_attributes(id: unrelated.id))
  end

  it "does not wake closed jobs" do
    closed = Factories.job_record(user: user, repository: repository, state: "closed", closure_reason: "pr_merged", finished_at: Time.current)
    WorkIntent.create!(
      repository: repository,
      kind: "ci_failure",
      state: "requested",
      scope_type: "job",
      scope_id: closed.id
    )

    described_class.call(repository)

    expect(WorkIntents::JobWakeup).not_to have_received(:call)
  end
end
