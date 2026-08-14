require "rails_helper"

RSpec.describe Workflows::ExternalPrFeedback do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) do
    Job.create!(
      user: user, repository: repository, owner_user: user, state: "implemented",
      kind: "external_pr", external_pr_number: 9,
      external_pr_fork: false, branch_name: "dependabot/bundler/rack-3.1.1"
    )
  end

  before do
    allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
      RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "disabled", criteria: [])
    )
  end

  it "materializes the same-repo external PR feedback chain, no coverage/metadata-refresh steps" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare respond grader_fanout grader_collect summarize_amend push ]
    )
  end

  it "uses trigger_kind external_pr_feedback" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.trigger_kind).to eq("external_pr_feedback")
  end

  context "when adversarial review is enabled" do
    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
        RepoAdversarialReviewPlan::Result.new(rounds: 1, source: ".syrus.yml", note: nil, criteria: [])
      )
    end

    it "inserts respond/adversarial_review loop before the grader retry chain" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).to eq(
        %w[ prepare respond adversarial_review respond grader_fanout grader_collect summarize_amend push ]
      )
    end
  end

  describe ".after_success" do
    it "marks the source pr_review_comments handled and addresses feedback on the job" do
      comment = PrReviewComment.create!(
        job: job, pr_type: "external", comment_kind: "issue",
        github_comment_id: 1, attributed_to: "job_owner", actionable: true,
        body: "please fix this", comment_created_at: 1.hour.ago
      )
      workflow = described_class.instantiate(
        job: job,
        artifacts: {
          "pr_comments" => [ { "author" => "owner-handle", "body" => "please fix this", "created_at" => 1.hour.ago.iso8601 } ],
          "pr_review_comment_ids" => [ comment.id ]
        }
      )

      described_class.after_success(workflow)

      expect(comment.reload.handling_state).to eq("handled")
      expect(job.reload.last_feedback_addressed_at).to be_present
    end
  end
end
