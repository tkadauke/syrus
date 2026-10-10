require "rails_helper"

RSpec.describe MergeTrainMultisectWorkflow, :ci_only do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:epic) { Factories.epic(user: user, repository: repository) }
  let(:owner_job) do
    Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_number: 1,
      pr_number: 501,
      branch_name: "syrus/issue-1"
    )
  end
  let(:train) do
    MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "main",
      integration_branch: "syrus/merge-train-epic-#{epic.id}-x"
    )
  end
  let(:workflow) do
    Workflow.create!(
      job: owner_job,
      trigger_kind: "merge_train",
      artifacts: { "merge_train_id" => train.id }
    )
  end
  let(:after_step) do
    Step.create!(
      workflow: workflow,
      kind: described_class::COLLECT_KIND,
      position: 1,
      placement_policy: Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE
    )
  end
  let(:evaluations) do
    [
      { round: 1, section_index: 0, member_ids: [ 10 ] },
      { round: 1, section_index: 1, member_ids: [ 11 ] },
      { round: 1, section_index: 2, member_ids: [ 12 ] }
    ]
  end
  let(:collect_details) { { round: 1, phase: "section" } }

  before do
    allow(StepDispatcher).to receive(:advance_from)
  end

  after do
    Feature.clear_enabled_cache!
  end

  it "chains section evaluations before collect when distributed DAG execution is disabled" do
    collect = described_class.append_collect_with_evaluations!(
      after_step: after_step,
      collect_details: collect_details,
      evaluations: evaluations
    )

    eval_steps = workflow.steps.where(kind: described_class::EVALUATE_KIND).order(:position).to_a
    expect(eval_steps.size).to eq(3)
    expect(eval_steps.map(&:placement_policy)).to all(eq(Step::PlacementPolicy::PINNED_WORKFLOW_WORKSPACE))
    expect(after_step.reload.next_step).to eq(eval_steps.first)
    expect(eval_steps.first.next_step).to eq(eval_steps.second)
    expect(eval_steps.second.next_step).to eq(eval_steps.third)
    expect(eval_steps.third.next_step).to eq(collect)
    expect(eval_steps.map(&:depends_on_step_ids)).to eq([
      [ after_step.id ],
      [ eval_steps.first.id ],
      [ eval_steps.second.id ]
    ])
    expect(collect.reload.depends_on_step_ids).to eq([ eval_steps.third.id ])
    expect(StepDispatcher).to have_received(:advance_from).with(after_step)
  end

  it "fans out section evaluations before collect when distributed DAG execution is enabled" do
    Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
      feature.category = "Operations"
      feature.name = "Distributed workflow DAG"
    end.update!(enabled: true)
    Feature.clear_enabled_cache!
    repository.update!(distributed_workflow_dag_enabled: true)

    collect = described_class.append_collect_with_evaluations!(
      after_step: after_step,
      collect_details: collect_details,
      evaluations: evaluations
    )

    eval_steps = workflow.steps.where(kind: described_class::EVALUATE_KIND).order(:position).to_a
    expect(eval_steps.size).to eq(3)
    expect(eval_steps.map(&:placement_policy)).to all(eq(Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT))
    expect(collect.placement_policy).to eq(Step::PlacementPolicy::CONTROL_PLANE)
    expect(after_step.reload.next_step).to eq(eval_steps.first)
    expect(eval_steps.map { |step| step.reload.next_step }).to all(eq(collect))
    expect(eval_steps.map(&:depends_on_step_ids)).to eq([
      [ after_step.id ],
      [ after_step.id ],
      [ after_step.id ]
    ])
    expect(collect.reload.depends_on_step_ids).to match_array(eval_steps.map(&:id))
    expect(StepDispatcher).to have_received(:advance_from).with(after_step)
  end
end
