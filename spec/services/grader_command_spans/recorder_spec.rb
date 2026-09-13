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

  it "uses the next free sequence when another writer claimed the expected sequence" do
    CommandSpan.create!(
      job: job,
      workflow: workflow,
      step: step,
      run: run,
      sequence: 1,
      name: "existing",
      command_excerpt: "printf existing",
      started_at: 1.minute.ago
    )

    described_class.new(
      run: run,
      step: step,
      workflow: workflow,
      plan: plan
    )

    expect(run.reload.command_spans.ordered.pluck(:name, :sequence)).to eq([
      [ "existing", 1 ],
      [ "printf ready #1", 2 ]
    ])
  end
end
