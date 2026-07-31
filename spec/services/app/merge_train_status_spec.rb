require "rails_helper"

RSpec.describe App::MergeTrainStatus do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:epic) { Factories.epic(user: user, repository: repository) }

  def member_job(issue_number)
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: issue_number,
      state: "landing",
      pr_number: 500 + issue_number,
      branch_name: "syrus/issue-#{issue_number}"
    )
  end

  def train_with_workflow(step_kind:, step_state:, run_attrs: {})
    a = member_job(1)
    b = member_job(2)
    train = MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: repository.default_branch,
      integration_branch: "syrus/merge-train-epic-#{epic.id}-1",
      state: "grading"
    )
    [ a, b ].each_with_index { |job, index| MergeTrainMember.create!(merge_train: train, job: job, position: index) }
    workflow = Workflow.create!(
      job: b,
      trigger_kind: "merge_train",
      state: "running",
      artifacts: { "merge_train_id" => train.id }
    )
    step = Step.create!(workflow: workflow, kind: step_kind, position: 0, state: step_state)
    Run.create!({ job: b, step: step, trigger_kind: "merge_train" }.merge(run_attrs))
    Step.create!(workflow: workflow, kind: "prepare", position: 1, state: "queued") if step_state == "succeeded"
    [ train, workflow, step ]
  end

  it "reports the reconciling phase for a running merge_train_reconcile step" do
    train_with_workflow(step_kind: "merge_train_reconcile", step_state: "running")

    payload = described_class.for_epic(epic)

    expect(payload).to include(
      phase: "reconciling",
      branch: "syrus/merge-train-epic-#{epic.id}-1",
      member_count: 2
    )
    expect(payload[:reconciliation]).to include(state: "running", result: "running")
  end

  it "reports no-op reconciliation when the reconcile run produced no diff" do
    train_with_workflow(
      step_kind: "merge_train_reconcile",
      step_state: "succeeded",
      run_attrs: { head_sha: "abc123", step_agent_diff: "" }
    )

    payload = described_class.for_epic(epic)

    expect(payload[:phase]).to eq("grading")
    expect(payload[:reconciliation]).to include(result: "no_changes", head_sha: "abc123", diff_bytes: 0)
  end

  it "reports committed reconciliation when the reconcile run produced a diff" do
    train_with_workflow(
      step_kind: "merge_train_reconcile",
      step_state: "succeeded",
      run_attrs: { head_sha: "def456", step_agent_diff: "diff --git a/app.rb b/app.rb\n" }
    )

    payload = described_class.for_epic(epic)

    expect(payload[:reconciliation]).to include(result: "committed", head_sha: "def456")
    expect(payload[:reconciliation][:diff_bytes]).to be_positive
  end

  it "reports failed trains with the failure reason" do
    train, workflow, step = train_with_workflow(step_kind: "merge_train_reconcile", step_state: "failed")
    train.update!(state: "failed", failure_reason: "merge_train_reconcile: working tree is not clean")
    workflow.update!(state: "failed")

    payload = described_class.for_epic(epic)

    expect(payload).to include(phase: "failed", failure_reason: "merge_train_reconcile: working tree is not clean")
    expect(payload[:reconciliation]).to include(step_id: step.id, state: "failed", result: "failed")
  end
end
