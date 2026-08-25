require "rails_helper"

RSpec.describe ProviderAvailabilityWakeup do
  include ActiveJob::TestHelper

  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  before { clear_enqueued_jobs }
  after { clear_enqueued_jobs }

  it "wakes provider-paused workflows from WorkUnit blocked state without workflow artifacts" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job, agent_provider: "codex")
    workflow.work_unit.block!(
      reason: WorkUnits::Gates::ProviderAvailability::REASON,
      blocked_until: 10.minutes.from_now,
      details: { "provider" => "codex" }
    )

    expect {
      described_class.call(provider: "codex", user: user)
    }.to have_enqueued_job(WorkflowPhaseAdmissionJob).with(workflow.id)
  end

  it "still wakes replay workflows recorded only in legacy artifacts" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = Workflow.create!(
      job: job,
      user: user,
      trigger_kind: "replay",
      state: "queued",
      agent_provider: "codex"
    )
    Step.create!(workflow: workflow, kind: "implement", position: 0)
    workflow.update!(
      artifacts: {
        "start_blocked_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON,
        "pause_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON
      }
    )

    expect {
      described_class.call(provider: "codex", user: user)
    }.to have_enqueued_job(WorkflowPhaseAdmissionJob).with(workflow.id)
  end

  it "ignores migrated artifact-only workflows that do not have a WorkUnit block" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = Workflow.create!(
      job: job,
      user: user,
      trigger_kind: "initial",
      state: "queued",
      agent_provider: "codex",
      artifacts: {
        "start_blocked_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON,
        "pause_reason" => StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON
      }
    )
    Step.create!(workflow: workflow, kind: "implement", position: 0)

    expect {
      described_class.call(provider: "codex", user: user)
    }.not_to have_enqueued_job(WorkflowPhaseAdmissionJob).with(workflow.id)
  end
end
