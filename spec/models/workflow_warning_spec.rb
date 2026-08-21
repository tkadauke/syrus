require "rails_helper"

RSpec.describe WorkflowWarning do
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step) { Step.create!(workflow: workflow, kind: "grader", position: 0) }

  def build_warning(**overrides)
    described_class.new({
      workflow: workflow,
      job: job,
      step: step,
      kind: "grader_side_effect",
      severity: "medium",
      title: "Grader left changes",
      state: "pending"
    }.merge(overrides))
  end

  describe "validations" do
    it "is valid with the required fields" do
      expect(build_warning).to be_valid
    end

    it "requires kind" do
      expect(build_warning(kind: nil)).not_to be_valid
    end

    it "requires title" do
      expect(build_warning(title: nil)).not_to be_valid
    end

    it "rejects unknown severities" do
      expect(build_warning(severity: "critical")).not_to be_valid
    end

    it "rejects unknown states" do
      expect(build_warning(state: "accepted")).not_to be_valid
    end

    it "does not require a step" do
      expect(build_warning(step: nil)).to be_valid
    end
  end

  describe "#dismiss!" do
    it "transitions a pending warning to dismissed" do
      warning = build_warning.tap(&:save!)

      expect(warning.dismiss!).to be true
      expect(warning.reload.state).to eq("dismissed")
    end

    it "returns false when already dismissed" do
      warning = build_warning(state: "dismissed").tap { |w| w.save!(validate: false) }

      expect(warning.dismiss!).to be false
    end
  end

  describe "#file_fix_job!" do
    it "stamps the created Job without changing state" do
      warning = build_warning.tap(&:save!)
      created_job = Factories.job(repository: job.repository)

      warning.file_fix_job!(created_job)

      expect(warning.reload.created_job).to eq(created_job)
      expect(warning.state).to eq("pending")
    end
  end

  describe "redaction" do
    it "redacts secrets out of title, suggested_prompt, and evidence" do
      warning = build_warning(
        title: "leaked https://x-access-token:abc123@github.com/acme/widgets.git",
        suggested_prompt: "fix https://x-access-token:abc123@github.com/acme/widgets.git",
        evidence: { "command" => "curl https://x-access-token:abc123@github.com/acme/widgets.git" }
      )

      expect(warning.redacted_title).not_to include("abc123")
      expect(warning.redacted_suggested_prompt).not_to include("abc123")
      expect(warning.redacted_evidence["command"]).not_to include("abc123")
    end

    it "handles nil suggested_prompt and evidence" do
      warning = build_warning(suggested_prompt: nil, evidence: nil)

      expect(warning.redacted_suggested_prompt).to be_nil
      expect(warning.redacted_evidence).to be_nil
    end
  end
end
