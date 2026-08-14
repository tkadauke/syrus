require "rails_helper"

RSpec.describe Workflows::Retry do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "open") }

  before do
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
      RepoVisualReviewPlan::Result.new(enabled: false, rounds: 1, source: "none", note: "disabled")
    )
  end

  it "materializes the standard chain with coverage_analyze always present" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ]
    )
  end

  context "when visual review is enabled" do
    before do
      allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
        RepoVisualReviewPlan::Result.new(enabled: true, rounds: 1, source: ".syrus.yml", note: nil)
      )
    end

    it "inserts an implement/visual_review loop before the grader retry chain" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement visual_review implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ]
      )
    end
  end
end
