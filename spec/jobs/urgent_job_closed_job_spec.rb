require "rails_helper"

RSpec.describe UrgentJobClosedJob do
  include ActiveJob::TestHelper

  let(:repository) { Factories.repository }
  let(:user) { repository.user }

  def create_urgent_job!(state: "closed")
    Factories.job_record(
      user: user,
      repository: repository,
      priority: "urgent",
      state: state
    )
  end

  def create_blocked_workflow!
    job = Factories.job_record(user: user, repository: repository, priority: "medium", state: "queued")
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    step = Step.create!(workflow: workflow, kind: "implement", position: 0)
    workflow.update!(artifacts: { "start_blocked_reason" => StepDispatcher::URGENT_BLOCK_REASON })
    [workflow, step]
  end

  it "starts held workflows when no open urgent jobs remain" do
    create_urgent_job!(state: "closed")
    workflow, step = create_blocked_workflow!

    expect {
      described_class.new.perform(repository.id)
    }.to change { step.runs.count }.by(1)
  end

  it "does not start workflows when another urgent job is still open" do
    create_urgent_job!(state: "closed")
    create_urgent_job!(state: "queued")
    _workflow, step = create_blocked_workflow!

    expect {
      described_class.new.perform(repository.id)
    }.not_to change { Run.count }
  end

  it "does not start workflows blocked for a different reason" do
    create_urgent_job!(state: "closed")
    workflow, step = create_blocked_workflow!
    workflow.update!(artifacts: { "start_blocked_reason" => "some_other_reason" })

    expect {
      described_class.new.perform(repository.id)
    }.not_to change { Run.count }
  end

  it "does not start workflows from a different repository" do
    create_urgent_job!(state: "closed")
    other_repo = Factories.repository
    other_job = Factories.job_record(user: other_repo.user, repository: other_repo, priority: "medium", state: "queued")
    other_workflow = Workflow.create!(job: other_job, trigger_kind: "initial")
    other_step = Step.create!(workflow: other_workflow, kind: "implement", position: 0)
    other_workflow.update!(artifacts: { "start_blocked_reason" => StepDispatcher::URGENT_BLOCK_REASON })

    expect {
      described_class.new.perform(repository.id)
    }.not_to change { other_step.runs.count }
  end

  it "is a no-op for an unknown repository id" do
    expect {
      described_class.new.perform(0)
    }.not_to raise_error
  end
end
