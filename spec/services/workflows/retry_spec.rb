require "rails_helper"

RSpec.describe Workflows::Retry do
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
    allow(RepoReviewPlanPlan).to receive(:for_job).and_return(
      RepoReviewPlanPlan::Result.new(enabled: false, source: "none", note: "disabled")
    )
  end

  it "materializes the standard chain with coverage_analyze always present" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare implement format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open ]
    )
  end

  context "when formatters, generated, and grade are all unconfigured" do
    before do
      allow(RepoGradeLoopPlan).to receive(:for_job).and_return(
        RepoGradeLoopPlan::Result.new(format_configured: false, generate_configured: false, graders_configured: false, source: ".syrus.yml", note: nil)
      )
    end

    it "materializes a bare implement step with no format/generate/grader steps at all" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement coverage_analyze dependency_audit summarize test_plan pr_open ]
      )
    end
  end

  context "when visual review is enabled" do
    before do
      allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
        RepoVisualReviewPlan::Result.new(enabled: true, rounds: 1, source: ".syrus.yml", note: nil)
      )
    end

    it "inserts a review-first visual_review loop before the grader retry chain, with no redundant implement" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement visual_review format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open ]
      )
      expect(workflow.steps.where(kind: "implement").count).to eq(1)
    end
  end

  context "when adversarial review is enabled" do
    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
        RepoAdversarialReviewPlan::Result.new(rounds: 1, source: ".syrus.yml", note: nil, criteria: [])
      )
    end

    it "inserts a review-first adversarial_review loop before the grader retry chain, with no redundant implement" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement adversarial_review format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open ]
      )
      expect(workflow.steps.where(kind: "implement").count).to eq(1)
    end

    it "gives the adversarial_review loop its own loop_id, separate from the bare leading implement" do
      workflow = described_class.instantiate(job: job)

      bare_implement = workflow.steps.find_by!(kind: "implement")
      review_step = workflow.steps.find_by!(kind: "adversarial_review")

      expect(bare_implement.loop_id).to be_nil
      expect(review_step.loop_id).to be_present
    end
  end

  context "when adversarial and visual review are both enabled" do
    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
        RepoAdversarialReviewPlan::Result.new(rounds: 1, source: ".syrus.yml", note: nil, criteria: [])
      )
      allow(RepoVisualReviewPlan).to receive(:for_job).and_return(
        RepoVisualReviewPlan::Result.new(enabled: true, rounds: 1, source: ".syrus.yml", note: nil)
      )
    end

    it "places adversarial review before visual review and the grader retry chain, with no redundant implement" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement adversarial_review visual_review format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open ]
      )
      expect(workflow.steps.where(kind: "implement").count).to eq(1)
    end

    it "uses distinct loop_ids for adversarial review, visual review, and the grader retry chain" do
      workflow = described_class.instantiate(job: job)

      adversarial = workflow.steps.find_by!(kind: "adversarial_review")
      visual = workflow.steps.find_by!(kind: "visual_review")
      grader = workflow.steps.find_by!(kind: "grader_collect")

      expect(adversarial.loop_id).to be_present
      expect(visual.loop_id).to be_present
      expect(grader.loop_id).to be_present
      expect([ adversarial.loop_id, visual.loop_id, grader.loop_id ].uniq.size).to eq(3)
    end
  end

  it "omits review_plan entirely when it is not configured" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.where(kind: "review_plan")).to be_empty
  end

  context "when review_plan is enabled" do
    before do
      allow(RepoReviewPlanPlan).to receive(:for_job).and_return(
        RepoReviewPlanPlan::Result.new(enabled: true, source: ".syrus.yml", note: nil)
      )
    end

    it "appends review_plan after pr_open" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind).last(2)).to eq(%w[ pr_open review_plan ])
    end
  end
end
