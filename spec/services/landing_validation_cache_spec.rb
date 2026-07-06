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

  describe ".record!" do
    it "writes required_graders_passed, SHAs, base_ref, and checked_at to the workflow artifact" do
      job = make_job
      workflow = make_workflow(job)

      freeze_time do
        described_class.record!(
          workflow: workflow,
          head_sha: "abc123",
          base_sha: "def456",
          base_ref: "main"
        )

        artifact = workflow.reload.artifact("landing_validation")
        expect(artifact).to include(
          "required_graders_passed" => true,
          "head_sha" => "abc123",
          "base_sha" => "def456",
          "base_ref" => "main",
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
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => true, "head_sha" => "current_sha" } })
      pr = double("pr", head: double(sha: "current_sha"), base: double(sha: "base", ref: "main"))

      expect(described_class.valid_for?(job: job, pr: pr)).to be true
    end

    it "ignores workflows where required_graders_passed is not true" do
      job = make_job
      make_workflow(job, artifacts: { "landing_validation" => { "required_graders_passed" => false, "head_sha" => "current_sha" } })
      pr = double("pr", head: double(sha: "current_sha"), base: double(sha: "base", ref: "main"))

      expect(described_class.valid_for?(job: job, pr: pr)).to be false
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
end
