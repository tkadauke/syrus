require "rails_helper"

RSpec.describe WorkUnits::TerminalLockCleanup do
  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(user: admin, repository: repository, state: "implemented", pr_number: 42) }

  def leaked_unit
    workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", state: "blocked", finished_at: 5.minutes.ago)
    unit = attach_work_unit(workflow, state: "blocked")
    [ workflow, unit ]
  end

  it "reports the exact mutations without changing records in dry-run mode" do
    workflow, unit = leaked_unit
    lock = unit.work_unit_locks.active.first

    result = described_class.call(work_unit: unit, dry_run: true)

    expect(result).to have_attributes(status: "eligible", mutation_count: 0)
    expect(result.eligibility.affected_ids).to include(work_unit_ids: [ unit.id ], workflow_ids: [ workflow.id ], lock_ids: [ lock.id ])
    expect(unit.reload).to be_blocked
    expect(lock.reload).to be_active
  end

  it "retires stale ownership and releases locks without changing Job, PR, or Workflow" do
    workflow, unit = leaked_unit
    intent = unit.work_intent
    before = job.attributes.slice("state", "pr_number", "branch_name")

    result = described_class.call(work_unit: unit)

    expect(result.status).to eq("applied")
    expect(unit.reload).to be_cancelled
    expect(unit.work_unit_locks.active).to be_empty
    expect(workflow.reload).to be_blocked
    expect(job.reload.attributes.slice("state", "pr_number", "branch_name")).to eq(before)
    expect(intent.reload).to be_requested
  end

  it "is an explicit no-op when repeated" do
    _workflow, unit = leaked_unit
    described_class.call(work_unit: unit)

    result = described_class.call(work_unit: unit)

    expect(result).to have_attributes(status: "noop", mutation_count: 0)
  end

  it "rejects cleanup when the terminal Workflow still has an active Run" do
    workflow, unit = leaked_unit
    step = workflow.steps.create!(kind: "implement", position: 0, iteration: 1, state: "running")
    run = step.runs.create!(job: job, user: admin, trigger_kind: "initial", agent_provider: "claude", state: "running")

    expect { described_class.call(work_unit: unit) }
      .to raise_error(RepairEligibility::Ineligible, /active Runs: #{run.id}/)
    expect(unit.reload).to be_blocked
    expect(unit.work_unit_locks.active).not_to be_empty
  end
end
