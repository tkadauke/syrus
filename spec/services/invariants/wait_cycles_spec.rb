require "rails_helper"

RSpec.describe Invariants::WaitCycles do
  let(:later) { Time.current + 1.hour }
  let(:repository) { Factories.repository }

  def queued_workflow(trigger_kind: "ci_failure")
    job = Factories.job_record(state: "approved", repository: repository)
    Workflow.create!(job: job, user: job.user, trigger_kind: trigger_kind, state: "queued")
  end

  def block!(workflow, reason:, on:)
    attach_work_unit(workflow, state: "blocked", blocked_reason: reason,
                               blocked_details: { "blocking_workflow_id" => on.id })
  end

  it "reports two blocked units that each wait on the other's workflow" do
    rebase = queued_workflow(trigger_kind: "stack_rebase")
    repair = queued_workflow
    rebase_unit = block!(rebase, reason: "patient_rebase_waiting_for_active_workflow", on: repair)
    repair_unit = block!(repair, reason: "epic_wide_workflow_active", on: rebase)

    violation = described_class.call(now: later).sole

    expect(violation.affected_ids["work_unit_ids"]).to contain_exactly(rebase_unit.id, repair_unit.id)
    expect(violation.affected_ids["job_ids"]).to contain_exactly(rebase.job_id, repair.job_id)
    expect(violation.details["cycle"].map { |entry| entry["blocked_reason"] })
      .to contain_exactly("patient_rebase_waiting_for_active_workflow", "epic_wide_workflow_active")
    expect(violation.message).to include(rebase_unit.slug, repair_unit.slug)
  end

  it "does not report a chain of waits that ends in runnable work" do
    running = queued_workflow
    attach_work_unit(running, state: "running")
    waiting = queued_workflow
    block!(waiting, reason: "epic_wide_workflow_active", on: running)

    expect(described_class.call(now: later)).to be_empty
  end

  it "waits out the grace period" do
    first = queued_workflow
    second = queued_workflow
    block!(first, reason: "epic_wide_workflow_active", on: second)
    block!(second, reason: "epic_wide_workflow_active", on: first)

    expect(described_class.call(now: Time.current)).to be_empty
    expect(described_class.call(now: later)).not_to be_empty
  end

  it "honours the Job scope" do
    first = queued_workflow
    second = queued_workflow
    block!(first, reason: "epic_wide_workflow_active", on: second)
    block!(second, reason: "epic_wide_workflow_active", on: first)

    expect(described_class.call(now: later, scope: Invariants::Scope.for_jobs([ first.job_id ]))).to be_empty
    expect(described_class.call(now: later, scope: Invariants::Scope.for_jobs([ first.job_id, second.job_id ]))).not_to be_empty
  end
end
