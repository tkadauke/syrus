require "rails_helper"

RSpec.describe Workflows::MergeTrain do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:epic) { Factories.epic(user: user, repository: repository) }
  let(:tip) { member_job(issue_number: 2) }

  def member_job(issue_number:)
    Factories.job_record(
      user: user, repository: repository, epic: epic,
      issue_number: issue_number, state: "landing",
      pr_number: 500 + issue_number, branch_name: "syrus/issue-#{issue_number}"
    )
  end

  context "without coverage configured" do
    before { allow(RepoCoveragePlanReader).to receive(:for_job).and_return(nil) }

    it "materializes the assemble → build → reconcile → prepare → graders → land chain" do
      train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
      workflow = described_class.instantiate(job: tip, artifacts: { "merge_train_id" => train.id })

      ordered_kinds = workflow.steps.order(:position).pluck(:kind)
      expect(ordered_kinds).to eq(
        %w[ merge_train_assemble merge_train_build merge_train_reconcile prepare grader_fanout grader_collect merge_train_land ]
      )
      expect(ordered_kinds.index("merge_train_reconcile")).to be < ordered_kinds.index("prepare")
      expect(ordered_kinds.index("merge_train_reconcile")).to be < ordered_kinds.index("grader_fanout")
      expect(Step::Kind.fetch("merge_train_reconcile").agentic).to be(true)
      expect(workflow.trigger_kind).to eq("merge_train")
      expect(described_class.queue_name).to eq(:merges)
    end
  end

  context "with coverage configured" do
    let(:coverage_plan) { instance_double(RepoCoveragePlan) }
    before { allow(RepoCoveragePlanReader).to receive(:for_job).and_return(coverage_plan) }

    it "inserts coverage_analyze after grader_collect and before merge_train_land" do
      train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
      workflow = described_class.instantiate(job: tip, artifacts: { "merge_train_id" => train.id })

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ merge_train_assemble merge_train_build merge_train_reconcile prepare grader_fanout grader_collect coverage_analyze merge_train_land ]
      )
    end
  end

  it "sets try_id on the merge_train_land step so StepDispatcher can find the recovery branch" do
    train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
    workflow = described_class.instantiate(job: tip, artifacts: { "merge_train_id" => train.id })

    land_step = workflow.steps.find_by!(kind: "merge_train_land")
    expect(land_step.details["try_id"]).to be_present

    try_node = workflow.chain_template.find { |n| n["type"] == "try" && n["step"] == "merge_train_land" }
    expect(try_node).to be_present
    expect(try_node["id"]).to eq(land_step.details["try_id"])
    expect(try_node.dig("on_failure", Steps::MergeTrainLand::BaseMoved::FAILURE_CODE)).to be_present
  end

  it "embeds the incremental-rebase failure branch in the chain_template" do
    train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
    workflow = described_class.instantiate(job: tip, artifacts: { "merge_train_id" => train.id })

    try_node = workflow.chain_template.find { |n| n["type"] == "try" && n["step"] == "merge_train_land" }
    branch = try_node.dig("on_failure", Steps::MergeTrainLand::BaseMoved::FAILURE_CODE)

    kinds = branch.map { |n| n["type"] == "step" ? n["kind"] : n["type"] }
    expect(kinds).to eq(%w[ merge_train_rebase retry_until merge_train_land_after_rebase ])
  end
end
