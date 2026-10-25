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
      base_retry: nil,
      deps: [],
      metadata: {}
    )
  end

  let(:plan) do
    RepoGradePlan::Result.new(
      graders: [
        grader("review-check", phases: %w[review]),
        grader("minimal-review-check", phases: %w[review_minimal]),
        grader("landing-check", phases: %w[landing]),
        grader("minimal-landing-check", phases: %w[landing_minimal]),
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
    it "preserves every trigger kind's phase when delivery uses its defaults" do
      repository = instance_double(Repository)
      job = instance_double(Job)
      policy = instance_double(DeliveryPolicy, review_grade_phase: "review", landing_grade_phase: "landing")
      allow(DeliveryPolicy).to receive(:for).with(repository: repository, job: job).and_return(policy)

      described_class::CI_TRIGGER_KINDS.each do |trigger_kind|
        expect(described_class.phase_for(trigger_kind: trigger_kind, iteration: 1, repository: repository, job: job)).to eq(:ci)
      end
      described_class::LANDING_TRIGGER_KINDS.each do |trigger_kind|
        expect(described_class.phase_for(trigger_kind: trigger_kind, iteration: 1, repository: repository, job: job)).to eq(:landing)
      end
      described_class::PROMOTION_TRIGGER_KINDS.each do |trigger_kind|
        expect(described_class.phase_for(trigger_kind: trigger_kind, iteration: 1, repository: repository, job: job)).to eq(:promotion)
      end
      expect(described_class.phase_for(trigger_kind: "initial", iteration: 1, repository: repository, job: job)).to eq(:review)
    end

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
    let(:repository) { instance_double(Repository) }
    let(:job) { instance_double(Job) }
    let(:policy) do
      instance_double(
        DeliveryPolicy,
        review_grade_phase: "review_minimal",
        landing_grade_phase: "landing_minimal"
      )
    end

    before do
      allow(DeliveryPolicy).to receive(:for).with(repository: repository, job: job).and_return(policy)
    end

    it "selects the Job track's custom review phase" do
      effective = described_class.effective(
        plan,
        trigger_kind: "initial",
        iteration: 1,
        repository: repository,
        job: job
      )

      expect(effective.graders.map(&:name)).to eq([ "minimal-review-check" ])
    end

    it "selects the Job track's custom landing phase" do
      effective = described_class.effective(
        plan,
        trigger_kind: "auto_merge",
        iteration: 1,
        repository: repository,
        job: job
      )

      expect(effective.graders.map(&:name)).to eq([ "minimal-landing-check" ])
    end

    it "uses the Job track's custom landing phase through the landing-plan helper" do
      effective = described_class.landing(plan, repository: repository, job: job)

      expect(effective.graders.map(&:name)).to eq([ "minimal-landing-check" ])
    end

    it "does not consult delivery policy for promotion or hotfix sync" do
      %w[promotion hotfix_sync].each do |trigger_kind|
        effective = described_class.effective(
          plan,
          trigger_kind: trigger_kind,
          iteration: 1,
          repository: repository,
          job: job
        )

        expect(effective.graders.map(&:name)).to eq([ "promotion-check" ])
      end

      expect(DeliveryPolicy).not_to have_received(:for)
    end

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

    it "selects only graders whose phases include review by default" do
      effective = described_class.effective(plan, trigger_kind: "initial", iteration: 1)

      expect(effective.graders.map(&:name)).to eq([ "review-check" ])
    end
  end
end
