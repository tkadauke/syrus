require "rails_helper"

RSpec.describe WorkUnits::TerminalLockCleanup do
  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(user: admin, repository: repository, state: "implemented", pr_number: 42) }

  def leaked_unit
    workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude")
    unit = attach_work_unit(workflow, state: "blocked", blocked_reason: "active_work_lock")
    workflow.update_columns(state: "blocked", finished_at: Time.current)
    [ workflow, unit ]
  end

  it "retires terminal Workflow ownership without changing valid Job, PR, Workflow, or intent facts" do
    workflow, unit = leaked_unit
    intent = unit.work_intent
    lock_ids = unit.work_unit_locks.active.ids

    result = described_class.call!(unit)

    expect(result).to be_eligible
    expect(unit.reload).to be_cancelled
    expect(unit.work_unit_locks.where(id: lock_ids).active).to be_empty
    expect(intent.reload).to be_requested
    expect(workflow.reload).to be_blocked
    expect(job.reload).to have_attributes(state: "implemented", pr_number: 42)
  end

  it "rejects active Runs and makes a repeated attempt an explicit ineligible no-op" do
    workflow, unit = leaked_unit
    step = workflow.steps.create!(kind: "implement", position: 0, state: "running")
    step.runs.create!(job: job, user: admin, trigger_kind: "initial", agent_provider: "claude", state: "running")

    expect(described_class.preflight(unit)).not_to be_eligible
    expect { described_class.call!(unit) }.to raise_error(ArgumentError, /queued or running Runs/)

    workflow.runs.update_all(state: "cancelled", finished_at: Time.current)
    described_class.call!(unit)
    expect(described_class.preflight(unit.reload)).not_to be_eligible
  end
end
