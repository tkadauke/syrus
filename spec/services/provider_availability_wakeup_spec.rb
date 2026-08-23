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

  it "still wakes legacy provider-paused workflows recorded only in artifacts" do
    job = Factories.job_record(user: user, repository: repository, state: "queued", agent_provider: "codex")
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: "codex")
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
end
