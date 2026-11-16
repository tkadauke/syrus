require "rails_helper"

RSpec.describe GraderCommandSpans::Recorder do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }
  let(:plan) { GraderCommandSpans::Plan.for("printf ready") }

  it "allocates the first sequence through the shared Run namespace" do
    described_class.new(
      run: run,
      step: step,
      workflow: workflow,
      plan: plan,
      idempotency_scope: "grader:#{step.id}"
    )

    expect(run.reload.command_spans.sole.sequence).to eq(1)
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
      plan: plan,
      idempotency_scope: "grader:#{step.id}"
    )

    expect(run.reload.command_spans.ordered.pluck(:name, :sequence)).to eq([
      [ "existing", 1 ],
      [ "printf ready #1", 2 ]
    ])
  end

  it "keeps command-span telemetry best-effort when allocation exhausts" do
    run.update!(state: "succeeded", finished_at: Time.current)
    messages = []
    allow(Rails.logger).to receive(:warn) { |message| messages << JSON.parse(message) }
    allow(CommandSpan).to receive(:record!).and_raise(ActiveRecord::LockWaitTimeout, "timeout")

    expect {
      described_class.new(
        run: run,
        step: step,
        workflow: workflow,
        plan: plan,
        idempotency_scope: "grader:#{step.id}"
      )
    }.not_to raise_error
    expect(run.reload.command_spans).to be_empty
    expect(messages).to include(hash_including(
      "event" => "command_span_allocation_exhausted",
      "run_id" => run.id,
      "attempts" => CommandSpan::MAX_ALLOCATION_ATTEMPTS,
      "error_class" => "ActiveRecord::LockWaitTimeout"
    ))

    expect(run.reload).to be_succeeded
  end
end
