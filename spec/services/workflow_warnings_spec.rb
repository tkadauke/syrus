require "rails_helper"

RSpec.describe WorkflowWarnings do
  let(:job) { Factories.job }
  let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
  let(:step) { Step.create!(workflow: workflow, kind: "grader", position: 0) }

  describe ".record!" do
    it "creates a pending WorkflowWarning linked to the workflow's job" do
      warning = described_class.record!(
        workflow: workflow,
        step: step,
        kind: "grader_side_effect",
        title: "Grader left changes",
        evidence: { "grader_name" => "tests" },
        suggested_prompt: "fix it"
      )

      expect(warning).to be_persisted
      expect(warning.job).to eq(job)
      expect(warning.workflow).to eq(workflow)
      expect(warning.step).to eq(step)
      expect(warning.kind).to eq("grader_side_effect")
      expect(warning.severity).to eq("medium")
      expect(warning.state).to eq("pending")
      expect(warning.evidence).to eq({ "grader_name" => "tests" })
      expect(warning.suggested_prompt).to eq("fix it")
    end

    it "works without a step, for kinds that aren't scoped to one" do
      warning = described_class.record!(workflow: workflow, kind: "something_new", title: "Finding")

      expect(warning.step).to be_nil
      expect(warning).to be_persisted
    end

    it "accepts an explicit severity" do
      warning = described_class.record!(workflow: workflow, kind: "something_new", title: "Finding", severity: "high")

      expect(warning.severity).to eq("high")
    end
  end
end
