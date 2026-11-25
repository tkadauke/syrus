require "rails_helper"

RSpec.describe WorkflowOutcomeOverrides::Resumer do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }

  it "reruns a failed grader collector so it consumes the recorded override" do
    grader = Step.create!(workflow:, kind: "grader", position: 10, state: "failed",
      iteration: 1, loop_id: "grade-loop")
    collector = Step.create!(workflow:, kind: "grader_collect", position: 11, state: "failed",
      iteration: 1, loop_id: "grade-loop")
    override = instance_double(WorkflowOutcomeOverride, workflow:, step: grader)
    result = RetryFailedStepEnqueuer::Result.new(run: instance_double(Run), workflow:, step: collector, error: nil)
    allow(workflow).to receive(:failed?).and_return(true)
    allow(RetryFailedStepEnqueuer).to receive(:call).and_return(result)

    expect(described_class.call(override:)).to eq(result)
    expect(RetryFailedStepEnqueuer).to have_received(:call).with(
      workflow:, failed_step: collector, restart_grade_loop: false
    )
  end

  it "does nothing until a workflow is actually blocked at the gate" do
    step = Step.create!(workflow:, kind: "grader", position: 10, state: "failed")
    override = instance_double(WorkflowOutcomeOverride, workflow:, step:)
    allow(workflow).to receive(:failed?).and_return(false)
    allow(RetryFailedStepEnqueuer).to receive(:call)

    expect(described_class.call(override:)).to be_nil
    expect(RetryFailedStepEnqueuer).not_to have_received(:call)
  end
end
