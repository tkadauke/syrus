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

  it "does not change WorkIntent state for failed or cancelled WorkUnits" do
    failed = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    other_job = Factories.job_record(user: user, repository: repository)
    cancelled = WorkUnits::Launcher.instantiate(kind: "manual_visual_review", job: other_job)

    failed.work_unit.mark_terminal!("failed")
    cancelled.work_unit.mark_terminal!("cancelled")

    expect(failed.work_unit.work_intent.reload).to be_requested
    expect(cancelled.work_unit.work_intent.reload).to be_requested
  end
end
