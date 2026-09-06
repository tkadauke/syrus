require "rails_helper"

RSpec.describe WorkEngineReconcilerActivityPruneJob do
  it "deletes reconciler activity events older than the retention window" do
    travel_to Time.zone.parse("2026-08-09 12:00:00 UTC") do
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "run_finished",
        source: "spec",
        message: "old",
        occurred_at: (WorkEngineReconcilerActivityEvent::RETAIN_AFTER + 1.second).ago
      )
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "run_finished",
        source: "spec",
        message: "fresh",
        occurred_at: WorkEngineReconcilerActivityEvent::RETAIN_AFTER.ago
      )
      # record! buffers; a reader flushes before querying, so the spec does too.
      Observability::EventSink.flush!(kinds: [ :work_engine_reconciler_activity ])

      expect { described_class.perform_now }.to change { WorkEngineReconcilerActivityEvent.count }.by(-1)

      expect(WorkEngineReconcilerActivityEvent.exists?(message: "old")).to be(false)
      expect(WorkEngineReconcilerActivityEvent.exists?(message: "fresh")).to be(true)
    end
  end
end
