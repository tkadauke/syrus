require "rails_helper"

RSpec.describe Workflows::Initial do
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

  context "when only formatters is configured" do
    before do
      allow(RepoGradeLoopPlan).to receive(:for_job).and_return(
        RepoGradeLoopPlan::Result.new(format_configured: true, generate_configured: false, graders_configured: false, source: ".syrus.yml", note: nil)
      )
    end

    it "shows format but not generate, and still shows the grade loop's grader_fanout/grader_collect" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement format grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
      )
    end
  end

  context "when only grade is configured" do
    before do
      allow(RepoGradeLoopPlan).to receive(:for_job).and_return(
        RepoGradeLoopPlan::Result.new(format_configured: false, generate_configured: false, graders_configured: true, source: ".syrus.yml", note: nil)
      )
    end

    it "shows grader_fanout/grader_collect without format or generate" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
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

      # The first `implement` is the always-present top-level step; the
      # second is the visual_review loop's own leading implement (untouched
      # by this fix — see Workflows::Initial's class comment).
      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement implement visual_review format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
      )
    end

    it "gives the visual_review loop its own loop_id, distinct from the top-level implement" do
      workflow = described_class.instantiate(job: job)

      review_step = workflow.steps.find_by!(kind: "visual_review")
      implement_steps = workflow.steps.order(:position).select { |s| s.kind == "implement" }

      top_level_implement = implement_steps.find { |s| s.loop_id.nil? }
      vr_implement        = implement_steps.find { |s| s.loop_id == review_step.loop_id }

      expect(top_level_implement).not_to be_nil
      expect(vr_implement).not_to be_nil
      expect(vr_implement.loop_id).not_to be_nil
      expect(top_level_implement.position).to be < vr_implement.position
    end

    context "and adversarial review is also enabled" do
      before do
        allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
          RepoAdversarialReviewPlan::Result.new(rounds: 1, source: ".syrus.yml", note: nil, criteria: [])
        )
      end

      it "places the visual_review loop after the adversarial_review loop and before the grader retry chain" do
        workflow = described_class.instantiate(job: job)

        expect(workflow.steps.order(:position).pluck(:kind)).to eq(
          %w[ prepare implement adversarial_review implement visual_review format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
        )
      end
    end
  end

  context "when adversarial review is enabled" do
    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
        RepoAdversarialReviewPlan::Result.new(rounds: 2, source: ".syrus.yml", note: nil, criteria: [])
      )
    end

    it "puts implement top-level and starts the adversarial_review loop with the review step alone" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement adversarial_review format generate grader_fanout grader_collect coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
      )
    end

    it "gives the top-level implement no loop_id, and the review step its own loop_id" do
      workflow = described_class.instantiate(job: job)

      implement = workflow.steps.find_by!(kind: "implement")
      review = workflow.steps.find_by!(kind: "adversarial_review")

      expect(implement.loop_id).to be_nil
      expect(review.loop_id).not_to be_nil
    end
  end

  context "when adversarial review and a configured grade loop are both enabled" do
    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
        RepoAdversarialReviewPlan::Result.new(rounds: 2, source: ".syrus.yml", note: nil, criteria: [])
      )
    end

    it "materializes a check-first retry_until node with implement only in the repair list" do
      workflow = described_class.instantiate(job: job)

      grade_node = workflow.chain_template.find { |node| node["type"] == "retry_until" }
      expect(grade_node).to include(
        "repair_first" => false,
        "repair" => %w[ implement ],
        "check" => %w[ format generate grader_fanout grader_collect ]
      )
    end
  end

  context "when adversarial review is enabled but no grade loop is configured" do
    before do
      allow(RepoAdversarialReviewPlan).to receive(:for_job).and_return(
        RepoAdversarialReviewPlan::Result.new(rounds: 2, source: ".syrus.yml", note: nil, criteria: [])
      )
      allow(RepoGradeLoopPlan).to receive(:for_job).and_return(
        RepoGradeLoopPlan::Result.new(format_configured: false, generate_configured: false, graders_configured: false, source: ".syrus.yml", note: nil)
      )
    end

    it "does not add a second implement step for the unconfigured grade loop" do
      workflow = described_class.instantiate(job: job)

      expect(workflow.steps.order(:position).pluck(:kind)).to eq(
        %w[ prepare implement adversarial_review coverage_analyze dependency_audit summarize test_plan pr_open review_plan ]
      )
      expect(workflow.steps.where(kind: "implement").count).to eq(1)
    end
  end

  it "places coverage_analyze outside the retry_until loop" do
    workflow = described_class.instantiate(job: job)

    steps = workflow.steps.order(:position).index_by(&:kind)
    expect(steps["coverage_analyze"].loop_id).to be_nil
    expect(steps["grader_collect"].loop_id).not_to be_nil
  end

  it "pins the provider from the job provider setting when created" do
    user.update!(agent_provider: "codex", codex_auth_mode: "api_key", codex_api_key: "sk-test")
    job.update_columns(agent_provider: "claude", job_provider_setting: "default")

    workflow = described_class.instantiate(job: job)

    expect(workflow.agent_provider).to eq("codex")
  end

  it "does not rewrite an existing workflow pin when the job provider setting changes" do
    workflow = described_class.instantiate(job: job, agent_provider: "claude")

    job.update_columns(job_provider_setting: "codex")

    expect(workflow.reload.agent_provider).to eq("claude")
  end
end
