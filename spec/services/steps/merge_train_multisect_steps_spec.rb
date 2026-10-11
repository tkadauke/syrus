require "rails_helper"

RSpec.describe "merge train multisect workflow steps", :ci_only do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:epic) { Factories.epic(user: user, repository: repository) }
  let(:train) do
    MergeTrain.create!(
      epic: epic,
      repository: repository,
      base_branch: "master",
      integration_branch: "syrus/merge-train-epic-#{epic.id}-x",
      integration_sha: "abc123"
    ).tap do |record|
      4.times do |index|
        job = Factories.job_record(
          user: user,
          repository: repository,
          epic: epic,
          issue_number: index + 1,
          state: "landing",
          pr_number: 500 + index,
          branch_name: "syrus/issue-#{index + 1}"
        )
        MergeTrainMember.create!(merge_train: record, job: job, position: index)
      end
    end
  end
  let(:members) { train.members.includes(:job).order(:position).to_a }
  let(:workflow) do
    Workflow.create!(
      job: members.last.job,
      trigger_kind: "merge_train",
      state: "running",
      artifacts: {
        "merge_train_id" => train.id,
        "merge_train_base_sha" => "base123",
        GraderLoopProgress::ARTIFACT_KEY => [
          { "iteration" => 1, "failing_set" => [ "spec/widgets_spec.rb\u0000Widget fails" ] }
        ]
      }
    )
  end

  around do |example|
    previous = MergeTrainFailureHandler.multisect_evaluator
    MergeTrainFailureHandler.multisect_evaluator = nil
    example.run
  ensure
    MergeTrainFailureHandler.multisect_evaluator = previous
  end

  def enable_distributed_workflow_dag!
    Feature.find_or_create_by!(slug: "distributed_workflow_dag") do |feature|
      feature.category = "Operations"
      feature.name = "Distributed workflow DAG"
    end.update!(enabled: true)
    repository.update!(distributed_workflow_dag_enabled: true)
  end

  it "records prepare metadata and materializes oracle evaluation as workflow steps" do
    enable_distributed_workflow_dag!
    allow_any_instance_of(MergeTrainMultisect::DeterminismGate).to receive(:reproducible?).and_return(true)
    allow_any_instance_of(MergeTrainMultisect::DeterminismGate).to receive(:payload).and_return({ "gate" => "stubbed" })
    AppSetting.current.update!(merge_train_multisect_section_width: 3)
    prepare = Step.create!(workflow: workflow, kind: "merge_train_multisect_prepare", position: 1)
    collect = Step.create!(workflow: workflow, kind: "merge_train_multisect_collect", position: 2, depends_on_ids: [ prepare.id ])
    prepare.update!(next_step_id: collect.id)
    run = Run.create!(job: workflow.job, step: prepare, trigger_kind: "merge_train")

    Steps::MergeTrainMultisectPrepare.new(run).call

    state = workflow.reload.artifact(Steps::MergeTrainMultisectStep::STATE_ARTIFACT_KEY)
    expect(state).to include(
      "selected_rung" => "multisect",
      "base_sha" => "base123",
      "integration_sha" => "abc123",
      "section_width" => 3
    )
    expect(state["candidate_train_members"].map { |entry| entry["job_id"] }).to eq(members.map(&:job_id))
    expect(state["failing_selector"]).to eq([ "spec/widgets_spec.rb\u0000Widget fails" ])
    expect(state["planned_sections"].size).to eq(2)

    oracle = workflow.steps.find_by(kind: "merge_train_multisect_evaluate")
    expect(oracle.details).to include("role" => "oracle", "round" => 0)
    expect(workflow.steps.where(kind: "merge_train_multisect_collect").where.not(id: collect.id).count).to eq(1)
  end

  it "represents sectioning as same-workflow evaluation runs instead of a hidden service loop" do
    enable_distributed_workflow_dag!
    allow_any_instance_of(MergeTrainMultisect::DeterminismGate).to receive(:reproducible?).and_return(true)
    allow_any_instance_of(MergeTrainMultisect::DeterminismGate).to receive(:payload).and_return({})
    AppSetting.current.update!(merge_train_multisect_section_width: 4)
    prepare = Step.create!(workflow: workflow, kind: "merge_train_multisect_prepare", position: 1)
    placeholder_collect = Step.create!(workflow: workflow, kind: "merge_train_multisect_collect", position: 2, depends_on_ids: [ prepare.id ])
    prepare.update!(next_step_id: placeholder_collect.id)
    prepare_run = Run.create!(job: workflow.job, step: prepare, trigger_kind: "merge_train")
    Steps::MergeTrainMultisectPrepare.new(prepare_run).call

    culprit = members.first
    MergeTrainFailureHandler.multisect_evaluator = lambda do |members:, role:, **|
      reproduced = role == "oracle" || members.include?(culprit)
      MergeTrainMultisect::Evaluation.new(reproduced, "stubbed", {})
    end
    oracle = workflow.steps.where(kind: "merge_train_multisect_evaluate").detect { |step| step.details.to_h["role"] == "oracle" }
    oracle_run = Run.create!(job: workflow.job, step: oracle, trigger_kind: "merge_train")
    Steps::MergeTrainMultisectEvaluate.new(oracle_run).call
    oracle_collect = workflow.steps.where(kind: "merge_train_multisect_collect").detect { |step| step.details.to_h["phase"] == "oracle" }
    collect_run = Run.create!(job: workflow.job, step: oracle_collect, trigger_kind: "merge_train")

    Steps::MergeTrainMultisectCollect.new(collect_run).call

    section_steps = workflow.steps.where(kind: "merge_train_multisect_evaluate").order(:position).select { |step| step.details.to_h["role"] == "section" }
    expect(section_steps.size).to eq(3)
    expect(section_steps.map(&:workflow_id).uniq).to eq([ workflow.id ])
    expect(section_steps.map { |step| step.details.to_h["round"] }.uniq).to eq([ 1 ])
    expect(section_steps.map { |step| step.details.to_h["section_index"] }).to eq([ 0, 1, 2 ])
    expect(section_steps.all? { |step| step.depends_on_step_ids == [ oracle_collect.id ] }).to eq(true)
    expect(section_steps.map(&:placement_policy).uniq).to eq([ Step::PlacementPolicy::IMMUTABLE_SOURCE_CHECKOUT ])
  end
end
