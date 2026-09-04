require "rails_helper"

RSpec.describe Remediation::Resolver do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.first }
  let(:step) { workflow.steps.first }

  describe "the resolution rule" do
    # step override -> template override -> work-definition policy -> problem default
    it "prefers a step override over every later tier" do
      step.update!(details: step.details.to_h.merge("remediation" => "skip"))

      result = described_class.call(problem: Problem[:timeout], step: step, workflow: workflow)

      expect(result.action).to eq(:skip)
      expect(result.source).to eq(:step_override)
    end

    it "prefers a template override over the work definition and the default" do
      workflow.update!(chain_template: [ { "kind" => step.kind, "remediation" => "advance" } ])

      result = described_class.call(problem: Problem[:timeout], step: step, workflow: workflow)

      expect(result.action).to eq(:advance)
      expect(result.source).to eq(:template_override)
    end

    it "asks the work definition's retry policy before the problem default" do
      result = described_class.call(problem: Problem[:timeout], step: step, workflow: workflow)

      expect(result.source).to eq(:work_definition)
    end

    it "falls back to the problem's own default" do
      result = described_class.call(problem: Problem[:rate_limited])

      expect(result.action).to eq(:defer)
      expect(result.source).to eq(:problem_default)
    end

    it "fails when there is no problem and no policy to ask" do
      result = described_class.call

      expect(result.action).to eq(:fail)
      expect(result.source).to eq(:problem_default)
    end
  end

  describe "work definition policies" do
    # work_definition builds a fresh object per call, so the double has to be
    # returned by that lookup rather than stubbed on one instance of it.
    def stub_policy(**answers)
      policy = instance_double("retry_policy", **answers)
      allow(workflow).to receive(:work_definition).and_return(instance_double("work_definition", retry_policy: policy))
    end

    it "resumes the step for a policy that treats it as a continuation" do
      stub_policy(rebuild_unit?: false, continuation?: true, new_attempt?: false)

      expect(described_class.call(step: step, workflow: workflow).action).to eq(:resume_step)
    end

    it "rebuilds the unit for a merge-train shaped policy" do
      stub_policy(rebuild_unit?: true, continuation?: false, new_attempt?: true)

      expect(described_class.call(step: step, workflow: workflow).action).to eq(:rebuild_unit)
    end

    it "restarts the workflow when the policy wants a fresh attempt" do
      stub_policy(rebuild_unit?: false, continuation?: false, new_attempt?: true)

      expect(described_class.call(step: step, workflow: workflow).action).to eq(:restart_workflow)
    end
  end

  # An override naming something outside the closed set is a bug in whatever
  # wrote it; abandoning the failure being handled would be worse than
  # ignoring it.
  it "ignores an unknown override and falls through" do
    step.update!(details: step.details.to_h.merge("remediation" => "improvise"))
    allow(Rails.logger).to receive(:warn)

    result = described_class.call(problem: Problem[:rate_limited], step: step, workflow: nil)

    expect(result.action).to eq(:defer)
    expect(Rails.logger).to have_received(:warn).with(/ignoring unknown step_override/)
  end
end
