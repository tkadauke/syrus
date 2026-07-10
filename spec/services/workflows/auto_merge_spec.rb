require "rails_helper"

RSpec.describe Workflows::AutoMerge do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", auto_merge_enabled: true) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "landing") }

  context "without coverage configured" do
    before { allow(RepoCoveragePlanReader).to receive(:for_job).and_return(nil) }

    it "materializes the standard chain without coverage_analyze" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ mergeability_preflight prepare grader_fanout grader_collect push auto_merge ]
      )
    end
  end

  context "with coverage configured" do
    let(:coverage_plan) { instance_double(RepoCoveragePlan) }
    before { allow(RepoCoveragePlanReader).to receive(:for_job).and_return(coverage_plan) }

    it "inserts coverage_analyze after grader_collect and before push" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ mergeability_preflight prepare grader_fanout grader_collect coverage_analyze push auto_merge ]
      )
    end
  end
end
