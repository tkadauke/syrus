require "rails_helper"

RSpec.describe Workflows::PrFeedback do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "open") }

  before do
    allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
      RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "disabled")
    )
  end

  it "materializes the standard chain with coverage steps always present" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare respond grader_fanout grader_collect coverage_analyze coverage_pr_comment summarize_amend push ]
    )
  end

  it "places coverage_analyze immediately after grader_collect and coverage_pr_comment before summarize_amend" do
    workflow = described_class.instantiate(job: job)

    kinds = workflow.steps.order(:position).pluck(:kind)
    collect_pos  = kinds.index("grader_collect")
    analyze_pos  = kinds.index("coverage_analyze")
    comment_pos  = kinds.index("coverage_pr_comment")
    summarize_pos = kinds.index("summarize_amend")

    expect(analyze_pos).to eq(collect_pos + 1)
    expect(comment_pos).to eq(analyze_pos + 1)
    expect(summarize_pos).to eq(comment_pos + 1)
  end

  context "when adversarial review is enabled" do
    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
        RepoAdversarialReviewPlan::Result.new(rounds: 1, source: ".syrus.yml", note: nil)
      )
    end

    it "inserts respond/adversarial_review loop before the grader retry chain" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).to eq(
        %w[ prepare respond adversarial_review respond grader_fanout grader_collect coverage_analyze coverage_pr_comment summarize_amend push ]
      )
    end

    it "puts the adversarial_review loop steps in the same loop_id" do
      workflow = described_class.instantiate(job: job)

      review_step = workflow.steps.find_by!(kind: "adversarial_review")
      # The respond step in the adversarial loop shares the reviewer's loop_id
      ar_loop_respond = workflow.steps.order(:position).find do |s|
        s.kind == "respond" && s.loop_id == review_step.loop_id
      end

      expect(ar_loop_respond).not_to be_nil
    end

    it "uses a different loop_id for the adversarial loop vs the grader retry chain" do
      workflow = described_class.instantiate(job: job)

      respond_steps = workflow.steps.order(:position).select { |s| s.kind == "respond" }
      review_step   = workflow.steps.find_by!(kind: "adversarial_review")

      ar_respond    = respond_steps.find { |s| s.loop_id == review_step.loop_id }
      retry_respond = respond_steps.find { |s| s.loop_id != review_step.loop_id }

      expect(ar_respond).not_to be_nil
      expect(retry_respond).not_to be_nil
      expect(ar_respond.position).to be < retry_respond.position
    end
  end
end
