require "rails_helper"

RSpec.describe WorkEngineReconcilerActivityEvent do
  it "records append-only reconciler activity with normalized JSON details" do
    job = Factories.job
    event = described_class.record!(
      event_type: "issues_detected",
      source: "spec",
      severity: "warn",
      job_id: job.id,
      issue_kind: "queued_run_without_queue_claim",
      repair_action: "reenqueue_run",
      message: "Run is queued without a queue claim.",
      details: { affected_ids: { job_ids: [ job.id ] } }
    )

    # record! buffers rather than writing through -- the reconciler emits tens
    # of thousands of these a day and a per-event INSERT was the largest source
    # of one-row writes in the system. It reports what it recorded; the row
    # appears on the next flush, which is what readers do before querying.
    expect(event["event_type"]).to eq("issues_detected")

    Observability::EventSink.flush!(kinds: [ :work_engine_reconciler_activity ])

    persisted = described_class.recent_first.find_by!(source: "spec")
    expect(persisted.details).to eq("affected_ids" => { "job_ids" => [ job.id ] })
    expect(persisted.issue_kind).to eq("queued_run_without_queue_claim")
    expect { persisted.update!(message: "changed") }.to raise_error(ActiveRecord::ReadOnlyRecord)
  end
end
