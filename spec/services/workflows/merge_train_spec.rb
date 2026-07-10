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

    it "materializes the assemble → build → prepare → graders → land chain" do
      train = MergeTrain.create!(epic: epic, repository: repository, base_branch: "master")
      workflow = described_class.instantiate(job: tip, artifacts: { "merge_train_id" => train.id })

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ merge_train_assemble merge_train_build prepare grader_fanout grader_collect merge_train_land ]
      )
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
        %w[ merge_train_assemble merge_train_build prepare grader_fanout grader_collect coverage_analyze merge_train_land ]
      )
    end
  end
end
