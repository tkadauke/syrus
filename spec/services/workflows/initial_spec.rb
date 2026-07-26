require "rails_helper"

RSpec.describe Workflows::Initial do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "open") }

  before do
    allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
      RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "disabled", criteria: [])
    )
  end

  it "materializes the standard chain with coverage_analyze always present" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ]
    )
  end

  it "places coverage_analyze outside the retry_until loop" do
    workflow = described_class.instantiate(job: job)

    steps = workflow.steps.order(:position).index_by(&:kind)
    expect(steps["coverage_analyze"].loop_id).to be_nil
    expect(steps["grader_collect"].loop_id).not_to be_nil
  end
end
