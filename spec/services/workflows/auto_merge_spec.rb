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

    it "does not insert coverage_analyze because landing uses fast graders" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ mergeability_preflight prepare grader_fanout grader_collect push auto_merge ]
      )
    end
  end

  describe ".after_success" do
    it "tries to land the queue and checks for a continuous-deploy trigger" do
      workflow = described_class.instantiate(job: job)

      expect(LandingQueueProcessor).to receive(:try_land!)
      expect(DeployContinuousTrigger).to receive(:after_landing!).with(repository)

      described_class.after_success(workflow)
    end
  end
end
