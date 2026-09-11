require "rails_helper"

RSpec.describe WorkUnits::Gates::CiRepairSafety do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:base_sha) { "abc1234567890000000000000000000000000000" }
  let(:head_sha) { "def1234567890000000000000000000000000000" }
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

  def step_for(workflow, kind:, position:)
    Step.create!(workflow: workflow, kind: kind, position: position)
  end

  def add_ci_retry_template!(workflow)
    workflow.update!(
      chain_template: [
        { "type" => "step", "kind" => "prepare" },
        {
          "type" => "retry_until",
          "max_iterations" => 3,
          "repair" => [ "analyze_and_fix" ],
          "check" => [ "grader_fanout", "grader_collect" ],
          "repair_first" => true
        },
        { "type" => "step", "kind" => "summarize_amend" }
      ]
    )
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
    repository.update!(main_branch_health_enabled: true, last_health_checked_sha: "older")
    unit = ci_unit_for(job)

    result = described_class.call(unit)

    expect(result).to be_blocked
    expect(result.details).to include("kind" => "base_not_known_healthy", "base_sha" => base_sha)
  end

  it "re-applies base health safety to later CI retry loop phases" do
    repository.update!(main_branch_health_enabled: true, last_health_checked_sha: "older")
    unit = ci_unit_for(job, state: "running")
    workflow = unit.workflow
    add_ci_retry_template!(workflow)
    step_for(workflow, kind: "prepare", position: 0)
    analyze = step_for(workflow, kind: "analyze_and_fix", position: 1).tap { |step| step.update!(loop_id: "loop-1") }
    grader = step_for(workflow, kind: "grader", position: 2).tap { |step| step.update!(loop_id: "loop-1") }
    summarize = step_for(workflow, kind: "summarize_amend", position: 3)

    launch_result = described_class.call(unit, step: workflow.first_step)
    analyze_result = described_class.call(unit, step: analyze)
    grader_result = described_class.call(unit, step: grader)
    summarize_result = described_class.call(unit, step: summarize)

    expect(launch_result).to be_blocked
    expect(launch_result.details).to include("kind" => "base_not_known_healthy")
    expect(analyze_result).to be_blocked
    expect(analyze_result.details).to include("kind" => "base_not_known_healthy")
    expect(grader_result).to be_blocked
    expect(grader_result.details).to include("kind" => "base_not_known_healthy")
    expect(summarize_result).to be_pass
  end

  it "reports an active main-branch repair for the same base before retrying CI repair" do
    repository.update!(main_branch_health_enabled: true, last_health_checked_sha: "older")
    unit = ci_unit_for(job, state: "running")
    workflow = unit.workflow
    add_ci_retry_template!(workflow)
    step_for(workflow, kind: "prepare", position: 0)
    analyze = step_for(workflow, kind: "analyze_and_fix", position: 1).tap { |step| step.update!(loop_id: "loop-1") }
    repair_job = Job.create!(
      user: user,
      repository: repository,
      kind: "direct",
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
      issue_title: Job::MAIN_BRANCH_REPAIR_TITLE,
      issue_body: "Main branch health is broken.\nCommit: #{base_sha}\n",
      issue_number: nil
    )
    repair_workflow = Workflow.create!(job: repair_job, trigger_kind: "main_branch_repair", state: "running")

    result = described_class.call(unit, step: analyze)

    expect(result).to be_blocked
    expect(result.details).to include(
      "kind" => "base_repair_active",
      "base_sha" => base_sha,
      "repair_workflow_id" => repair_workflow.id,
      "repair_job_id" => repair_job.id,
      "repair_trigger_kind" => "main_branch_repair"
    )
  end

  it "does not require healthy base evidence when main-branch health checking is disabled" do
    repository.update!(main_branch_health_enabled: false, last_health_checked_sha: "older")
    unit = ci_unit_for(job)

    result = described_class.call(unit)

    expect(result).to be_pass
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

  it "ignores unowned queued CI repair workflows when checking for duplicates" do
    other = Factories.job_record(user: user, repository: repository, issue_number: 44, state: "approved", commits_behind_base: 0)
    Workflow.create!(
      job: other,
      trigger_kind: "ci_failure",
      state: "queued",
      artifacts: { "head_sha" => "other-head", "base_sha" => base_sha }
    )
    unit = ci_unit_for(job)

    result = described_class.call(unit)

    expect(result).to be_pass
  end
end
