require "rails_helper"

RSpec.describe WorkspaceReuseOutcomes::Recorder do
  let(:job) { Factories.job }
  let(:workflow) { job.workflows.last }
  let(:step) { workflow.steps.first }
  let(:run) { step.runs.first || step.runs.create!(job: job, trigger_kind: workflow.trigger_kind) }

  it "persists queryable outcome identity" do
    described_class.record(
      run: run,
      kind: "grader_fanout",
      outcome: "overlay",
      prepare_fingerprint: "abc123",
      materialization_method: "overlay",
      grader_count: 4,
      duration_seconds: 1.25
    )

    expect(WorkspaceReuseOutcome.last).to have_attributes(
      repository_id: job.repository_id,
      workflow_id: workflow.id,
      step_id: step.id,
      run_id: run.id,
      kind: "grader_fanout",
      outcome: "overlay",
      prepare_fingerprint: "abc123",
      materialization_method: "overlay",
      grader_count: 4,
      backend: "local"
    )
  end

  it "never propagates recording failures" do
    allow(WorkspaceReuseOutcome).to receive(:create!).and_raise(ActiveRecord::StatementInvalid, "unavailable")

    expect {
      described_class.record(run: run, kind: "prepare", outcome: "rebuilt")
    }.not_to raise_error
  end

  it "updates outcomes when the router resolves the actual backend" do
    described_class.record(run: run, kind: "prepare", outcome: "rebuilt")

    expect {
      described_class.record_backend(run: run, backend: "container_execution")
    }.to change { WorkspaceReuseOutcome.last.backend }.from("local").to("container_execution")
  end
end
