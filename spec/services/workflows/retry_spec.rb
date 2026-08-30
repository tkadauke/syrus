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
  end

  it "materializes the standard chain with coverage_analyze always present" do
    workflow = described_class.instantiate(job: job)

    expect(workflow.steps.order(:position).pluck(:kind)).to eq(
      %w[ prepare implement format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
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
        %w[ prepare implement coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
      )
    end
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
        %w[ prepare implement visual_review implement format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
      )
    end
  end

  context "when adversarial review is enabled" do
    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
        RepoAdversarialReviewPlan::Result.new(rounds: 1, source: ".syrus.yml", note: nil, criteria: [])
      )
    end

    it "inserts an implement/adversarial_review loop before the grader retry chain" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement adversarial_review implement format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
      )
    end

    it "puts the adversarial_review loop steps in the same loop_id" do
      workflow = described_class.instantiate(job: job)

      review_step = workflow.steps.find_by!(kind: "adversarial_review")
      review_implement = workflow.steps.order(:position).find do |step|
        step.kind == "implement" && step.loop_id == review_step.loop_id
      end

      expect(review_implement).not_to be_nil
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

    it "places adversarial review before visual review and the grader retry chain" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement adversarial_review implement visual_review implement format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
      )
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
end
