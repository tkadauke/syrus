require "rails_helper"

# Regression: a CI repair deferred at start (its agent provider was out) and
# then blocked on `branch_behind_base` once main moved could never run -- only a
# rebase clears that block, and a rebase preempts the repair -- yet it held its
# queued Job, whose own retry reads the latest Workflow, forever. The reconciler
# now cancels it as superseded, without waiting out the first-Run grace period.
RSpec.describe "Cancelling a CI repair held behind base" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:head_sha) { "def1234567890000000000000000000000000000" }
  let(:job) do
    Factories.job_record(
      user: user,
      repository: repository,
      state: "queued",
      pr_number: 84,
      branch_name: "syrus/direct-published",
      commits_behind_base: 2,
      last_ci_handled_sha: head_sha
    )
  end

  def blocked_ci_repair!(kind: "branch_behind_base")
    artifacts = { "head_sha" => head_sha, "base_sha" => "abc1234567890000000000000000000000000000" }
    workflow = Workflow.create!(job: job, trigger_kind: "ci_failure", state: "queued", artifacts: artifacts)
    Step.create!(workflow: workflow, kind: "prepare", position: 0, state: "queued")
    intent = WorkIntent.create!(
      kind: "ci_failure", state: "requested", repository: repository,
      scope_type: "job", scope_id: job.id, actor: user, source_type: "spec",
      payload_artifacts: artifacts
    )
    unit = WorkUnit.create!(
      work_intent: intent, kind: "ci_failure", state: "queued", repository: repository,
      scope_type: "job", scope_id: job.id, workflow: workflow
    )
    unit.work_unit_members.create!(job: job, role: "primary")
    unit.block!(
      reason: WorkUnits::Gates::CiRepairSafety::REASON,
      blocked_until: 5.minutes.from_now,
      details: { "kind" => kind, "job_id" => job.id, "commits_behind_base" => job.commits_behind_base }
    )
    workflow
  end

  def reconcile!
    WorkEngine::Reconciler.call(source: "spec", job_id: job.id, execute_repairs: true)
  end

  it "cancels the repair at once and hands its failure back to the poller" do
    workflow = blocked_ci_repair!

    result = reconcile!

    expect(result.repair_executions.map(&:action)).to include("cancel_superseded_ci_repair")
    expect(workflow.reload).to be_cancelled
    expect(workflow.artifact("cancelled_reason")).to eq(WorkUnits::Gates::CiRepairSafety::SUPERSEDED_BASE_REASON)
    expect(workflow.artifact("superseded_ci_repair_block_kind")).to eq("branch_behind_base")
    expect(workflow.work_unit.reload).to be_cancelled
    expect(job.reload.last_ci_handled_sha).to be_nil
  end

  it "leaves the repair alone once the branch has caught up, so its gate clears by itself" do
    workflow = blocked_ci_repair!
    job.update_columns(commits_behind_base: 0)

    reconcile!

    expect(workflow.reload).to be_queued
    expect(job.reload.last_ci_handled_sha).to eq(head_sha)
  end

  it "still waits out the grace period for a block that can clear" do
    workflow = blocked_ci_repair!(kind: "duplicate_active_ci_repair")

    reconcile!

    expect(workflow.reload).to be_queued
  end

  describe "CiRepairSafety.moot_block?" do
    it "is moot behind base whatever the base, and only while the branch is behind" do
      expect(WorkUnits::Gates::CiRepairSafety.moot_block?(job, "branch_behind_base", nil)).to be(true)

      job.commits_behind_base = 0
      expect(WorkUnits::Gates::CiRepairSafety.moot_block?(job, "branch_behind_base", nil)).to be(false)
    end

    it "never cancels a block that can still clear" do
      %w[ci_repair_disabled base_sha_unknown duplicate_active_ci_repair].each do |kind|
        expect(WorkUnits::Gates::CiRepairSafety.moot_block?(job, kind, "abc")).to be(false)
      end
    end
  end
end
