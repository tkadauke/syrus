require "rails_helper"

RSpec.describe WorkIntents::TerminalUnitSync do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository) }

  it "satisfies a requested WorkIntent when its WorkUnit succeeds" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    intent = workflow.work_unit.work_intent

    workflow.work_unit.mark_terminal!("succeeded")

    expect(intent.reload).to have_attributes(state: "satisfied")
    expect(intent.satisfied_at).to be_present
  end

  it "satisfies a waiting WorkIntent when its successful WorkUnit has no active siblings" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    intent = workflow.work_unit.work_intent
    intent.wait!(reason: "dependency", details: { "blocked_by_job_ids" => [ 123 ] })

    workflow.work_unit.mark_terminal!("succeeded")

    expect(intent.reload).to have_attributes(
      state: "satisfied",
      wait_reason: "dependency",
      wait_details: { "blocked_by_job_ids" => [ 123 ] }
    )
  end

  it "does not satisfy the WorkIntent while another WorkUnit for it is still active" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    intent = workflow.work_unit.work_intent
    WorkUnit.create!(
      work_intent: intent,
      kind: "initial",
      state: "queued",
      repository: repository,
      scope_type: "job",
      scope_id: job.id
    )

    workflow.work_unit.mark_terminal!("succeeded")

    expect(intent.reload).to be_requested
  end

  it "fails a requested WorkIntent when its only WorkUnit fails" do
    failed = WorkUnits::Launcher.instantiate(kind: "initial", job: job)

    failed.work_unit.mark_terminal!("failed")

    expect(failed.work_unit.work_intent.reload).to be_failed
  end

  it "does not fail the WorkIntent while another WorkUnit for it is still active" do
    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    intent = workflow.work_unit.work_intent
    WorkUnit.create!(
      work_intent: intent,
      kind: "initial",
      state: "queued",
      repository: repository,
      scope_type: "job",
      scope_id: job.id
    )

    workflow.work_unit.mark_terminal!("failed")

    expect(intent.reload).to be_requested
  end

  it "does not change WorkIntent state for ordinary cancelled WorkUnits" do
    other_job = Factories.job_record(user: user, repository: repository)
    cancelled = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: other_job)

    cancelled.work_unit.mark_terminal!("cancelled")

    expect(cancelled.work_unit.work_intent.reload).to be_requested
  end

  it "cancels a requested WorkIntent when its only WorkUnit is superseded by a rebase" do
    workflow = WorkUnits::Launcher.instantiate(kind: "ci_failure", job: job)
    intent = workflow.work_unit.work_intent

    workflow.work_unit.preempt!(reason: Workflow::SUPERSEDED_BY_REBASE_REASON)

    expect(intent.reload).to have_attributes(state: "cancelled")
    expect(intent.cancelled_at).to be_present
  end

  it "cancels a requested retry WorkIntent when it is superseded by approval" do
    workflow = WorkUnits::Launcher.instantiate(kind: "retry", job: job)
    intent = workflow.work_unit.work_intent

    workflow.work_unit.preempt!(reason: "job_approved")

    expect(intent.reload).to have_attributes(state: "cancelled")
    expect(intent.cancelled_at).to be_present
  end

  it "does not cancel a superseded WorkIntent while another WorkUnit for it is still active" do
    workflow = WorkUnits::Launcher.instantiate(kind: "ci_failure", job: job)
    intent = workflow.work_unit.work_intent
    WorkUnit.create!(
      work_intent: intent,
      kind: "ci_failure",
      state: "queued",
      repository: repository,
      scope_type: "job",
      scope_id: job.id
    )

    workflow.work_unit.preempt!(reason: Workflow::SUPERSEDED_BY_REBASE_REASON)

    expect(intent.reload).to be_requested
  end
end
