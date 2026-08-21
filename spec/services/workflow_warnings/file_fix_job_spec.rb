require "rails_helper"

RSpec.describe WorkflowWarnings::FileFixJob do
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:warning) do
    WorkflowWarnings.record!(
      workflow: workflow,
      kind: "grader_side_effect",
      title: "Grader left changes",
      suggested_prompt: "Fix the grader"
    )
  end

  describe ".call" do
    it "creates a direct Job from the prompt and stamps created_job on the warning" do
      result = described_class.call(warning: warning, actor: job.user, prompt: "Fix the grader please")

      expect(result).to be_ok
      expect(result.job).to be_persisted
      expect(result.job.kind).to eq("direct")
      expect(result.job.issue_number).to be_nil
      expect(result.job.issue_body).to eq("Fix the grader please")
      expect(result.job.repository).to eq(job.repository)
      expect(result.warning.created_job).to eq(result.job)
      expect(result.message).to include(result.job.slug)
    end

    it "strips and requires a non-blank prompt" do
      result = described_class.call(warning: warning, actor: job.user, prompt: "   ")

      expect(result).not_to be_ok
      expect(result.message).to match(/blank/i)
      expect(warning.reload.created_job).to be_nil
    end

    it "allows the operator-edited prompt to differ from suggested_prompt" do
      result = described_class.call(warning: warning, actor: job.user, prompt: "A completely different prompt")

      expect(result.job.issue_body).to eq("A completely different prompt")
    end
  end
end
