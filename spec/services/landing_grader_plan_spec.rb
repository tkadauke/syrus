require "rails_helper"

RSpec.describe LandingGraderPlan do
  def grader(name, phases:)
    RepoGradePlan::Grader.new(
      name: name,
      command: "echo #{name}",
      phases: phases,
      description: nil,
      required: true,
      timeout_minutes: 5,
      when_files_changed: nil,
      junit_output: nil,
      failures: "strict",
      metadata: {}
    )
  end

  let(:plan) do
    RepoGradePlan::Result.new(
      graders: [
        grader("review-check", phases: %w[review]),
        grader("landing-check", phases: %w[landing]),
        grader("ci-check", phases: %w[ci]),
        grader("promotion-check", phases: %w[promotion])
      ],
      source: ".syrus.yml",
      note: nil,
      max_iterations: 3,
      rerun_only_failed: false
    )
  end

  describe ".phase_for" do
    it "maps ci_failure, main_grader, and main_branch_repair to :ci" do
      expect(described_class.phase_for(trigger_kind: "ci_failure", iteration: 1)).to eq(:ci)
      expect(described_class.phase_for(trigger_kind: "main_grader", iteration: 1)).to eq(:ci)
      expect(described_class.phase_for(trigger_kind: "main_branch_repair", iteration: 1)).to eq(:ci)
    end

    it "maps auto_merge and merge_train to :landing" do
      expect(described_class.phase_for(trigger_kind: "auto_merge", iteration: 1)).to eq(:landing)
      expect(described_class.phase_for(trigger_kind: "merge_train", iteration: 1)).to eq(:landing)
    end

    it "maps promotion to :promotion" do
      expect(described_class.phase_for(trigger_kind: "promotion", iteration: 1)).to eq(:promotion)
    end

    it "maps hotfix_sync to :promotion (there is no separate built-in hotfix_sync grade phase)" do
      expect(described_class.phase_for(trigger_kind: "hotfix_sync", iteration: 1)).to eq(:promotion)
    end

    it "falls back to :review for everything else" do
      expect(described_class.phase_for(trigger_kind: "initial", iteration: 1)).to eq(:review)
      expect(described_class.phase_for(trigger_kind: "pr_comment", iteration: 1)).to eq(:review)
    end
  end

  describe ".effective" do
    it "selects only graders whose phases include the promotion phase for trigger_kind promotion" do
      effective = described_class.effective(plan, trigger_kind: "promotion", iteration: 1)

      expect(effective.graders.map(&:name)).to eq([ "promotion-check" ])
      expect(effective.graders.first.metadata).to include("phase" => "promotion", "configured_phases" => %w[promotion])
    end

    it "selects the same promotion-phase graders for trigger_kind hotfix_sync" do
      effective = described_class.effective(plan, trigger_kind: "hotfix_sync", iteration: 1)

      expect(effective.graders.map(&:name)).to eq([ "promotion-check" ])
    end

    it "selects only graders whose phases include landing for trigger_kind auto_merge" do
      effective = described_class.effective(plan, trigger_kind: "auto_merge", iteration: 1)

      expect(effective.graders.map(&:name)).to eq([ "landing-check" ])
    end

    it "selects only graders whose phases include ci for trigger_kind main_branch_repair" do
      effective = described_class.effective(plan, trigger_kind: "main_branch_repair", iteration: 1)

      expect(effective.graders.map(&:name)).to eq([ "ci-check" ])
    end

    it "selects only graders whose phases include review by default" do
      effective = described_class.effective(plan, trigger_kind: "initial", iteration: 1)

      expect(effective.graders.map(&:name)).to eq([ "review-check" ])
    end
  end
end
