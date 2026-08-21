require "rails_helper"

RSpec.describe LandingValidationCache do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  def make_job
    Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 42)
  end

  def make_workflow(job, artifacts: {})
    Workflow.create!(job: job, trigger_kind: "initial", artifacts: artifacts)
  end

  def changed_files_fingerprint(files = [ "app/models/job.rb" ])
    described_class.changed_files_fingerprint(files)
  end

  describe ".record!" do
    it "writes required_graders_passed, SHAs, base_ref, and checked_at to the workflow artifact" do
      job = make_job
      workflow = make_workflow(job)

      freeze_time do
        described_class.record!(
          workflow: workflow,
          head_sha: "abc123",
          tree_sha: "tree123",
          base_sha: "def456",
          base_tree_sha: "base-tree123",
          base_ref: "main",
          grader_fingerprint: "grade-fp",
          changed_files_fingerprint: changed_files_fingerprint
        )

        artifact = workflow.reload.artifact("landing_validation")
        expect(artifact).to include(
          "required_graders_passed" => true,
          "head_sha" => "abc123",
          "tree_sha" => "tree123",
          "base_sha" => "def456",
          "base_tree_sha" => "base-tree123",
          "base_ref" => "main",
          "grader_fingerprint" => "grade-fp",
          "changed_files_fingerprint" => changed_files_fingerprint,
          "validation_source" => "graders",
          "checked_at" => Time.current.iso8601
        )
      end
    end

    it "omits nil SHA / ref values from the recorded artifact" do
      job = make_job
      workflow = make_workflow(job)

      described_class.record!(workflow: workflow, head_sha: nil, base_sha: nil, base_ref: nil)

      artifact = workflow.reload.artifact("landing_validation")
      expect(artifact.keys).not_to include("head_sha", "base_sha", "base_ref")
    end
  end

  describe ".valid_for?" do
    it "returns false when PR head SHA is blank" do
      job = make_job
      pr = double("pr", head: double(sha: ""), base: double(sha: "base", ref: "main"))

      expect(described_class.valid_for?(job: job, pr: pr)).to be false
    end

    it "returns false when no matching workflow exists for the head SHA" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => true, "head_sha" => "old_sha" } })
      pr = double("pr", head: double(sha: "new_sha"), base: double(sha: "base", ref: "main"))

      expect(described_class.valid_for?(job: job, pr: pr)).to be false
    end

    it "returns true when a workflow has a green validation for the current head SHA" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => true, "head_sha" => "current_sha", "base_sha" => "base", "base_ref" => "main" } })
      pr = double("pr", head: double(sha: "current_sha"), base: double(sha: "base", ref: "main"))

      expect(described_class.valid_for?(job: job, pr: pr)).to be true
    end

    it "keeps exact-head reuse for legacy artifacts without base identity" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => true, "head_sha" => "current_sha" } })
      pr = double("pr", head: double(sha: "current_sha"), base: double(sha: "base", ref: "main"))

      decision = described_class.decision_for_pr(job: job, pr: pr)

      expect(decision).to be_reusable
      expect(decision.match_type).to eq("exact_head")
      expect(decision.reason).to eq("legacy exact-head validation match")
    end

    it "returns false when the PR base changed" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => true, "head_sha" => "current_sha", "base_sha" => "old_base", "base_ref" => "main" } })
      pr = double("pr", head: double(sha: "current_sha"), base: double(sha: "new_base", ref: "main"))

      expect(described_class.valid_for?(job: job, pr: pr)).to be false
    end

    it "ignores workflows where required_graders_passed is not true" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => false, "head_sha" => "current_sha" } })
      pr = double("pr", head: double(sha: "current_sha"), base: double(sha: "base", ref: "main"))

      expect(described_class.valid_for?(job: job, pr: pr)).to be false
    end
  end

  describe ".reusable_for?" do
    it "returns an exact_head hit when head, base, and grader fingerprint match" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "abc",
        "tree_sha" => "tree-a",
        "base_sha" => "base",
        "base_ref" => "main",
        "grader_fingerprint" => "fp"
      } })

      decision = described_class.reusable_for?(job: job, head_sha: "abc", tree_sha: "tree-a", base_sha: "base", base_ref: "main", grader_fingerprint: "fp")

      expect(decision).to be_reusable
      expect(decision.match_type).to eq("exact_head")
    end

    it "returns a same_tree hit when a different head has the same validated tree" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "old-head",
        "tree_sha" => "same-tree",
        "base_sha" => "base",
        "base_ref" => "main",
        "grader_fingerprint" => "fp"
      } })

      decision = described_class.reusable_for?(job: job, head_sha: "new-head", tree_sha: "same-tree", base_sha: "base", base_ref: "main", grader_fingerprint: "fp")

      expect(decision).to be_reusable
      expect(decision.match_type).to eq("same_tree")
    end

    it "rejects reuse when the required grader configuration changed" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "abc",
        "tree_sha" => "tree",
        "base_sha" => "base",
        "base_ref" => "main",
        "grader_fingerprint" => "old-fp"
      } })

      decision = described_class.reusable_for?(job: job, head_sha: "abc", tree_sha: "tree", base_sha: "base", base_ref: "main", grader_fingerprint: "new-fp")

      expect(decision).not_to be_reusable
      expect(decision.reason).to eq("required grader configuration changed")
    end

    it "rejects reuse when the cached validation lacks the current grader fingerprint identity" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "abc",
        "tree_sha" => "tree",
        "base_sha" => "base",
        "base_ref" => "main"
      } })

      decision = described_class.reusable_for?(job: job, head_sha: "abc", tree_sha: "tree", base_sha: "base", base_ref: "main", grader_fingerprint: "fp")

      expect(decision).not_to be_reusable
      expect(decision.reason).to eq("cached validation is missing required grader configuration")
    end

    it "rejects reuse when the base SHA changed" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "abc",
        "tree_sha" => "tree",
        "base_sha" => "old-base",
        "base_ref" => "main",
        "grader_fingerprint" => "fp"
      } })

      decision = described_class.reusable_for?(job: job, head_sha: "abc", tree_sha: "tree", base_sha: "new-base", base_ref: "main", grader_fingerprint: "fp")

      expect(decision).not_to be_reusable
      expect(decision.reason).to include("base SHA changed")
    end

    it "accepts reuse when the base SHA changed but the base tree matches" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "speculative-head",
        "tree_sha" => "tree",
        "base_sha" => "predicted-base",
        "base_tree_sha" => "same-base-tree",
        "base_ref" => "main",
        "grader_fingerprint" => "fp"
      } })

      decision = described_class.reusable_for?(
        job: job,
        head_sha: "speculative-head",
        tree_sha: "tree",
        base_sha: "actual-base",
        base_tree_sha: "same-base-tree",
        base_ref: "main",
        grader_fingerprint: "fp"
      )

      expect(decision).to be_reusable
      expect(decision.reason).to eq("head/base/grader configuration match")
    end

    it "labels clean rebase carry-forward hits explicitly" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "rebased-head",
        "tree_sha" => "tree",
        "base_sha" => "base",
        "base_ref" => "main",
        "grader_fingerprint" => "fp",
        "validation_source" => "clean_rebase"
      } })

      decision = described_class.reusable_for?(job: job, head_sha: "rebased-head", tree_sha: "tree", base_sha: "base", base_ref: "main", grader_fingerprint: "fp")

      expect(decision).to be_reusable
      expect(decision.match_type).to eq("clean_rebase_carry_forward")
    end

    it "rejects stale validations" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "abc",
        "tree_sha" => "tree",
        "base_sha" => "base",
        "base_ref" => "main",
        "grader_fingerprint" => "fp",
        "checked_at" => 8.days.ago.iso8601
      } })

      decision = described_class.reusable_for?(job: job, head_sha: "abc", tree_sha: "tree", base_sha: "base", base_ref: "main", grader_fingerprint: "fp")

      expect(decision).not_to be_reusable
      expect(decision.reason).to include("older than")
    end
  end

  describe ".valid_head_for?" do
    it "returns false for blank head SHA" do
      job = make_job
      expect(described_class.valid_head_for?(job: job, head_sha: "")).to be false
      expect(described_class.valid_head_for?(job: job, head_sha: nil)).to be false
    end

    it "returns true when a workflow artifact matches the given head SHA" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => true, "head_sha" => "abc" } })

      expect(described_class.valid_head_for?(job: job, head_sha: "abc")).to be true
    end

    it "returns false when no workflow matches the head SHA" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => true, "head_sha" => "abc" } })

      expect(described_class.valid_head_for?(job: job, head_sha: "xyz")).to be false
    end
  end

  describe ".green_validation_present?" do
    it "returns false when no workflows have a landing_validation artifact" do
      job = make_job
      make_workflow(job)

      expect(described_class.green_validation_present?(job)).to be false
    end

    it "returns true when any workflow has required_graders_passed: true (regardless of SHA)" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => true, "head_sha" => "old" } })

      expect(described_class.green_validation_present?(job)).to be true
    end

    it "returns false when all artifacts have required_graders_passed: false" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => false, "head_sha" => "old" } })

      expect(described_class.green_validation_present?(job)).to be false
    end

    it "returns true when at least one workflow is green even if others are not" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => false } })
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => true, "head_sha" => "sha2" } })

      expect(described_class.green_validation_present?(job)).to be true
    end
  end

  describe "epicless job-bundle vs Epic-train cache isolation" do
    it "never lets a job-bundle member's cached validation satisfy an unrelated Epic-train member sharing the same repo/base, even with a colliding head SHA" do
      epic = Factories.epic(user: user, repository: repository, state: "ready")
      bundle_job = Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 101)
      epic_job = Factories.job_record(user: user, repository: repository, state: "approved", pr_number: 102, epic: epic)

      bundle_train = MergeTrain.create!(repository: repository, base_branch: "main", priority: "medium")
      MergeTrainMember.create!(merge_train: bundle_train, job: bundle_job, position: 0)

      epic_train = MergeTrain.create!(repository: repository, base_branch: "main", epic: epic)
      MergeTrainMember.create!(merge_train: epic_train, job: epic_job, position: 0)

      bundle_workflow = Workflow.create!(job: bundle_job, trigger_kind: "merge_train", artifacts: { "merge_train_id" => bundle_train.id })
      described_class.record!(
        workflow: bundle_workflow,
        head_sha: "shared-head",
        base_sha: "base-sha",
        base_ref: "main",
        grader_fingerprint: "fp"
      )

      # LandingValidationCache only ever scans a Job's own workflows
      # (`job.workflows`), and each train/bundle records its result onto its
      # own tip Job's own Workflow. So the job-bundle's green validation must
      # never satisfy the unrelated Epic-train member, even though repo,
      # base_ref, base_sha, and grader fingerprint all collide.
      cross_decision = described_class.reusable_for?(
        job: epic_job, head_sha: "shared-head", base_sha: "base-sha", base_ref: "main", grader_fingerprint: "fp"
      )
      expect(cross_decision.reusable?).to be false

      own_decision = described_class.reusable_for?(
        job: bundle_job, head_sha: "shared-head", base_sha: "base-sha", base_ref: "main", grader_fingerprint: "fp"
      )
      expect(own_decision.reusable?).to be true
      expect(own_decision.workflow).to eq(bundle_workflow)
    end
  end

  describe "throughput metric artifact compatibility" do
    it "records supported skip match types for debug payload consumers" do
      job = make_job
      workflow = make_workflow(job)
      decision = described_class::Decision.new(
        true,
        "tree/base/grader configuration match",
        "same_tree",
        { "head_sha" => "old" },
        make_workflow(job)
      )

      LandingThroughputMetrics.record_validation_decision!(
        workflow: workflow,
        decision: decision,
        context: "merge_train",
        head_sha: "new",
        base_sha: "base"
      )

      expect(workflow.reload.artifact(LandingThroughputMetrics::ARTIFACT_KEY).dig("validation_decisions").last).to include(
        "context" => "merge_train",
        "outcome" => "skipped",
        "match_type" => "same_tree",
        "reason" => "tree/base/grader configuration match",
        "head_sha" => "new",
        "base_sha" => "base"
      )
    end
  end

  describe ".carry_forward_source_for" do
    it "accepts a successful required-grader validation with the current grader fingerprint" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "old-head",
        "base_sha" => "old-base",
        "base_ref" => "main",
        "grader_fingerprint" => "fp",
        "changed_files_fingerprint" => changed_files_fingerprint,
        "validation_source" => "graders"
      } })

      decision = described_class.carry_forward_source_for(
        job: job,
        base_ref: "main",
        grader_fingerprint: "fp",
        changed_files_fingerprint: changed_files_fingerprint
      )

      expect(decision).to be_reusable
      expect(decision.match_type).to eq("clean_rebase_carry_forward_source")
    end

    it "rejects carry-forward from another carried validation" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "old-head",
        "base_sha" => "old-base",
        "base_ref" => "main",
        "grader_fingerprint" => "fp",
        "changed_files_fingerprint" => changed_files_fingerprint,
        "validation_source" => "clean_rebase"
      } })

      decision = described_class.carry_forward_source_for(
        job: job,
        base_ref: "main",
        grader_fingerprint: "fp",
        changed_files_fingerprint: changed_files_fingerprint
      )

      expect(decision).not_to be_reusable
      expect(decision.reason).to eq("no prior required-grader validation matched current grader configuration")
    end

    it "rejects carry-forward when .syrus.yml changes the landing grader fingerprint" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "old-head",
        "base_sha" => "old-base",
        "base_ref" => "main",
        "grader_fingerprint" => "old-fp",
        "changed_files_fingerprint" => changed_files_fingerprint
      } })

      decision = described_class.carry_forward_source_for(
        job: job,
        base_ref: "main",
        grader_fingerprint: "new-fp",
        changed_files_fingerprint: changed_files_fingerprint
      )

      expect(decision).not_to be_reusable
      expect(decision.reason).to eq("required grader configuration changed")
    end

    it "rejects carry-forward when the changed-file selection changed" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "old-head",
        "base_sha" => "old-base",
        "base_ref" => "main",
        "grader_fingerprint" => "fp",
        "changed_files_fingerprint" => changed_files_fingerprint([ "app/old.rb" ])
      } })

      decision = described_class.carry_forward_source_for(
        job: job,
        base_ref: "main",
        grader_fingerprint: "fp",
        changed_files_fingerprint: changed_files_fingerprint([ "app/new.rb" ])
      )

      expect(decision).not_to be_reusable
      expect(decision.reason).to eq("changed-file selection changed")
    end

    it "rejects carry-forward when the base ref changed" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => {
        "required_graders_passed" => true,
        "head_sha" => "old-head",
        "base_sha" => "old-base",
        "base_ref" => "release",
        "grader_fingerprint" => "fp",
        "changed_files_fingerprint" => changed_files_fingerprint
      } })

      decision = described_class.carry_forward_source_for(
        job: job,
        base_ref: "main",
        grader_fingerprint: "fp",
        changed_files_fingerprint: changed_files_fingerprint
      )

      expect(decision).not_to be_reusable
      expect(decision.reason).to eq("base ref changed from release to main")
    end
  end
end
