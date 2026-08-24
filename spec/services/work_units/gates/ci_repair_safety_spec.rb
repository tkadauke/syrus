require "rails_helper"

RSpec.describe WorkUnits::Gates::CiRepairSafety do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:base_sha) { "base123456789000000000000000000000000000" }
  let(:head_sha) { "head123456789000000000000000000000000000" }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "approved", commits_behind_base: 0) }

  def ci_unit_for(target_job, artifacts: { "head_sha" => head_sha, "base_sha" => base_sha }, state: "queued")
    workflow = Workflow.create!(job: target_job, trigger_kind: "ci_failure", state: state, artifacts: artifacts)
    intent = WorkIntent.create!(
      kind: "ci_failure",
      state: "requested",
      repository: target_job.repository,
      scope_type: "job",
      scope_id: target_job.id,
      actor: target_job.user,
      source_type: "spec",
      payload_artifacts: artifacts
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: "ci_failure",
      state: state,
      repository: target_job.repository,
      scope_type: "job",
      scope_id: target_job.id,
      workflow: workflow
    )
    unit.work_unit_members.create!(job: target_job, role: "primary")
    unit
  end

  before do
    repository.update!(
      last_health_checked_sha: base_sha,
      last_ci_evaluated_sha: base_sha,
      last_graded_sha: base_sha,
      ci_health: "healthy",
      grader_health: "healthy"
    )
  end

  it "passes CI repair when the base is known healthy and no duplicate repair is active" do
    unit = ci_unit_for(job)

    result = described_class.call(unit)

    expect(result).to be_pass
  end

  it "blocks CI repair when the branch is known behind its base" do
    job.update!(commits_behind_base: 3)
    unit = ci_unit_for(job)

    result = described_class.call(unit)

    expect(result).to be_blocked
    expect(result.reason).to eq("ci_repair_safety")
    expect(result.details).to include(
      "kind" => "branch_behind_base",
      "commits_behind_base" => 3
    )
  end

  it "blocks CI repair until the base SHA has healthy main-branch evidence" do
    repository.update!(last_health_checked_sha: "older")
    unit = ci_unit_for(job)

    result = described_class.call(unit)

    expect(result).to be_blocked
    expect(result.details).to include("kind" => "base_not_known_healthy", "base_sha" => base_sha)
  end

  it "blocks duplicate CI repairs for the same repository base SHA" do
    other = Factories.job_record(user: user, repository: repository, issue_number: 43, state: "approved", commits_behind_base: 0)
    duplicate = ci_unit_for(other, state: "running")
    unit = ci_unit_for(job)

    result = described_class.call(unit)

    expect(result).to be_blocked
    expect(result.details).to include(
      "kind" => "duplicate_active_ci_repair",
      "duplicate_workflow_id" => duplicate.workflow_id,
      "duplicate_job_id" => other.id
    )
  end
end
