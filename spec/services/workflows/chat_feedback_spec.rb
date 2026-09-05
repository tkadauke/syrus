require "rails_helper"

RSpec.describe Workflows::ChatFeedback do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "open") }

  before do
    allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
      RepoAdversarialReviewPlan::Result.new(rounds: 0, source: "none", note: "disabled", criteria: [])
    )
    allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
      RepoVisualReviewPlan::Result.new(enabled: false, rounds: 1, source: "none", note: "disabled")
    )
    allow(RepoGradeLoopPlan).to receive(:for_job).and_return(
      RepoGradeLoopPlan::Result.new(format_configured: true, generate_configured: true, graders_configured: true, source: ".syrus.yml", note: nil)
    )
  end

  it "materializes the standard chain with coverage steps always present" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare respond format generate grader_fanout grader_collect coverage_analyze coverage_pr_comment dependency_audit dependency_audit_pr_comment summarize_amend refresh_job_metadata push ]
    )
  end

  context "when formatters, generated, and grade are all unconfigured" do
    before do
      allow(RepoGradeLoopPlan).to receive(:for_job).and_return(
        RepoGradeLoopPlan::Result.new(format_configured: false, generate_configured: false, graders_configured: false, source: ".syrus.yml", note: nil)
      )
    end

    it "materializes a bare respond step with no format/generate/grader steps at all" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare respond coverage_analyze coverage_pr_comment dependency_audit dependency_audit_pr_comment summarize_amend refresh_job_metadata push ]
      )
    end
  end

  it "places metadata refresh after summarize_amend and before push" do
    workflow = described_class.instantiate(job: job)

    kinds = workflow.steps.order(:position).pluck(:kind)
    collect_pos      = kinds.index("grader_collect")
    analyze_pos      = kinds.index("coverage_analyze")
    comment_pos      = kinds.index("coverage_pr_comment")
    audit_pos        = kinds.index("dependency_audit")
    audit_comment_pos = kinds.index("dependency_audit_pr_comment")
    summarize_pos    = kinds.index("summarize_amend")
    refresh_pos      = kinds.index("refresh_job_metadata")
    push_pos         = kinds.index("push")

    expect(analyze_pos).to eq(collect_pos + 1)
    expect(comment_pos).to eq(analyze_pos + 1)
    expect(audit_pos).to eq(comment_pos + 1)
    expect(audit_comment_pos).to eq(audit_pos + 1)
    expect(summarize_pos).to eq(audit_comment_pos + 1)
    expect(refresh_pos).to eq(summarize_pos + 1)
    expect(push_pos).to eq(refresh_pos + 1)
  end

  context "when adversarial review is enabled" do
    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
        RepoAdversarialReviewPlan::Result.new(rounds: 2, source: ".syrus.yml", note: nil, criteria: [])
      )
    end

    it "inserts a review-first respond/adversarial_review loop before the grader retry chain, with no redundant respond" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).to eq(
        %w[ prepare respond adversarial_review format generate grader_fanout grader_collect coverage_analyze coverage_pr_comment dependency_audit dependency_audit_pr_comment summarize_amend refresh_job_metadata push ]
      )
      expect(workflow.steps.where(kind: "respond").count).to eq(1)
    end

    it "gives adversarial_review its own loop_id, distinct from the grader retry chain's and from the bare leading respond" do
      workflow = described_class.instantiate(job: job)

      bare_respond = workflow.steps.find_by!(kind: "respond")
      review_step  = workflow.steps.find_by!(kind: "adversarial_review")
      grader_step  = workflow.steps.find_by!(kind: "grader_collect")

      expect(bare_respond.loop_id).to be_nil
      expect(review_step.loop_id).to be_present
      expect(grader_step.loop_id).to be_present
      expect(review_step.loop_id).not_to eq(grader_step.loop_id)
    end
  end

  context "when visual review is enabled" do
    before do
      allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
        RepoVisualReviewPlan::Result.new(enabled: true, rounds: 1, source: ".syrus.yml", note: nil)
      )
    end

    it "inserts a review-first respond/visual_review loop before the grader retry chain, with no redundant respond" do
      workflow = described_class.instantiate(job: job)

      kinds = workflow.steps.order(:position).pluck(:kind)
      expect(kinds).to eq(
        %w[ prepare respond visual_review format generate grader_fanout grader_collect coverage_analyze coverage_pr_comment dependency_audit dependency_audit_pr_comment summarize_amend refresh_job_metadata push ]
      )
      expect(workflow.steps.where(kind: "respond").count).to eq(1)
    end

    it "gives visual_review its own loop_id, distinct from the grader retry chain's" do
      workflow = described_class.instantiate(job: job)

      review_step = workflow.steps.find_by!(kind: "visual_review")
      grader_step = workflow.steps.find_by!(kind: "grader_collect")

      expect(review_step.loop_id).to be_present
      expect(grader_step.loop_id).to be_present
      expect(review_step.loop_id).not_to eq(grader_step.loop_id)
    end
  end
end
