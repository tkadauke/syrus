require "rails_helper"

RSpec.describe GraderCommandSpans::Recorder do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:plan) { GraderCommandSpans::Plan.for("printf ready") }

  it "offsets persisted sequence numbers so one run can record multiple command groups" do
    described_class.new(
      run: run,
      step: step,
      workflow: workflow,
      plan: plan,
      sequence_offset: 3
    )

    expect(run.reload.command_spans.sole.sequence).to eq(4)
  end
end
