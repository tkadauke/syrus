require "rails_helper"

RSpec.describe Invariants::PausedRebaseHolds do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:later) { Time.current + 2.hours }

  def job(state:, **attrs)
    Factories.job_record(user: user, repository: repository, state: state, **attrs)
  end

  def rebase_for(target, state: "blocked", blocked_reason: WorkUnits::Gates::ManualPause::REASON, member_jobs: nil)
    workflow = Workflow.create!(job: target, user: user, trigger_kind: "stack_rebase", state: "running")
    Step.create!(workflow: workflow, kind: "stack_agent_rebase", position: 0)
    attach_work_unit(workflow, state: state, blocked_reason: blocked_reason, member_jobs: member_jobs)
    workflow.work_unit.update_columns(blocked_at: Time.current) if state == "blocked"
    workflow
  end

  # Regression: a paused rebase blocked the merge train for its stack with
  # "active rebase workflow must finish", which never happens without an
  # operator, and nothing in the monitor said so.
  it "reports a paused rebase holding approved Jobs of its stack" do
    root = job(state: "approved", pr_number: 10, branch_name: "syrus/root")
    child = job(state: "approved", pr_number: 11, branch_name: "syrus/child", parent_job: root)
    workflow = rebase_for(root, member_jobs: [ root, child ])

    violations = described_class.call(now: later)

    expect(violations.size).to eq(1)
    violation = violations.first
    expect(violation.fingerprint).to eq("paused_rebase_holds:WorkUnit:#{workflow.work_unit.id}")
    expect(violation.severity).to eq("warning")
    expect(violation.details["held_jobs"].map { |held| held["id"] }).to contain_exactly(root.id, child.id)
    expect(violation.affected_ids["job_ids"]).to include(root.id, child.id)
    expect(violation.message).to include(workflow.slug, root.slug, "operator")
  end

  it "reports a paused rebase on a stack parent that holds an approved child" do
    root = job(state: "implemented", pr_number: 10, branch_name: "syrus/root")
    child = job(state: "approved", pr_number: 11, branch_name: "syrus/child", parent_job: root)
    rebase_for(root, member_jobs: [ root ])

    violation = described_class.call(now: later).sole
    expect(violation.details["held_jobs"].map { |held| held["id"] }).to eq([ child.id ])
  end

  it "does not report before min_age" do
    root = job(state: "approved", pr_number: 10, branch_name: "syrus/root")
    rebase_for(root)

    expect(described_class.call(now: Time.current + 10.minutes)).to be_empty
  end

  it "does not report a paused rebase that holds no approved work" do
    root = job(state: "implemented", pr_number: 10, branch_name: "syrus/root")
    rebase_for(root)

    expect(described_class.call(now: later)).to be_empty
  end

  it "does not report a rebase blocked on a reason that clears by itself" do
    root = job(state: "approved", pr_number: 10, branch_name: "syrus/root")
    rebase_for(root, blocked_reason: "provider_availability")

    expect(described_class.call(now: later)).to be_empty
  end

  it "honours the scope" do
    root = job(state: "approved", pr_number: 10, branch_name: "syrus/root")
    other = job(state: "approved", pr_number: 12)
    rebase_for(root)

    expect(described_class.call(now: later, scope: Invariants::Scope.for_jobs([ other.id ]))).to be_empty
    expect(described_class.call(now: later, scope: Invariants::Scope.for_jobs([ root.id ])).size).to eq(1)
  end
end
