require "rails_helper"

RSpec.describe Workflows::Retry do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "open") }

  before do
    allow(RepoAdversarialReviewPlan).to receive(:for_job)
      .with(job)
      .and_return(RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "no .syrus.yml", criteria: []))
  end

  it "materializes the standard chain with coverage_analyze always present" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ]
    )
  end

  it "inserts the adversarial review loop before graders when enabled" do
    allow(RepoAdversarialReviewPlan).to receive(:for_job)
      .with(job)
      .and_return(RepoAdversarialReviewPlan::Result.new(rounds: 1, source: ".syrus.yml", note: nil, criteria: []))

    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare implement adversarial_review implement grader_fanout grader_collect coverage_analyze summarize test_plan pr_open ]
    )
  end
end
