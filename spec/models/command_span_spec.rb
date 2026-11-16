require "rails_helper"

RSpec.describe CommandSpan do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }

  def record_span(key:, name: key)
    described_class.record!(
      run: run,
      idempotency_key: key,
      job: job,
      workflow: workflow,
      step: step,
      name: name,
      command_excerpt: "printf ready",
      started_at: Time.current,
      metadata: {}
    )
  end

  it "returns the committed semantic event when persistence is retried" do
    first = record_span(key: "grader:1")
    retried = record_span(key: "grader:1", name: "duplicate")

    expect(retried).to eq(first)
    expect(run.command_spans.pluck(:sequence, :name, :idempotency_key)).to eq([
      [ 1, "grader:1", "grader:1" ]
    ])
  end

  it "allocates a gap-free sequence across semantic events" do
    first = record_span(key: "grader:1")
    second = record_span(key: "grader:2")

    expect([ first.sequence, second.sequence ]).to eq([ 1, 2 ])
  end
end
