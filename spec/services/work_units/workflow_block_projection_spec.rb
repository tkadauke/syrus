require "rails_helper"

RSpec.describe WorkUnits::WorkflowBlockProjection do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }
  let(:workflow) { WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: job) }

  it "projects legacy start-blocked reasons onto typed work unit reasons" do
    described_class.record!(
      workflow,
      start_blocked_reason: StepDispatcher::ADMISSION_BLOCK_REASON,
      blocked_until: 5.minutes.from_now,
      details: { "queue" => "busy" }
    )

    unit = workflow.work_unit.reload
    expect(unit).to have_attributes(state: "blocked", blocked_reason: "admission_control")
    expect(unit.blocked_details).to include(
      "queue" => "busy",
      "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON
    )
  end

  it "maps unknown start-blocked reasons to preemption until they get first-class gates" do
    described_class.record!(
      workflow,
      start_blocked_reason: StepDispatcher::EPIC_WIDE_BLOCK_REASON,
      blocked_until: nil,
      details: nil
    )

    expect(workflow.work_unit.reload).to have_attributes(state: "blocked", blocked_reason: "preempted")
  end

  it "clears only matching projected block reasons" do
    described_class.record!(
      workflow,
      start_blocked_reason: StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON,
      blocked_until: 5.minutes.from_now
    )

    described_class.clear!(workflow, start_blocked_reason: StepDispatcher::ADMISSION_BLOCK_REASON)
    expect(workflow.work_unit.reload).to have_attributes(state: "blocked", blocked_reason: "provider_availability")

    described_class.clear!(workflow, start_blocked_reason: StepDispatcher::PROVIDER_AVAILABILITY_BLOCK_REASON)
    expect(workflow.work_unit.reload).to have_attributes(state: "queued", blocked_reason: nil)
  end
end
