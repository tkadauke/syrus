require "rails_helper"

RSpec.describe Workflows::PrFeedback do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "open") }

  context "without coverage configured" do
    before { allow(RepoCoveragePlanReader).to receive(:for_job).and_return(nil) }

    it "materializes the standard chain without coverage_analyze" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare respond grader_fanout grader_collect summarize_amend push ]
      )
    end
  end

  context "with coverage configured" do
    let(:coverage_plan) { instance_double(RepoCoveragePlan) }
    before { allow(RepoCoveragePlanReader).to receive(:for_job).and_return(coverage_plan) }

    it "inserts coverage_analyze after grader_collect and before summarize_amend" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      collect_pos = kinds.index("grader_collect")
      analyze_pos = kinds.index("coverage_analyze")
      summarize_pos = kinds.index("summarize_amend")

      expect(analyze_pos).to eq(collect_pos + 1)
      expect(summarize_pos).to eq(analyze_pos + 1)
    end
  end
end
