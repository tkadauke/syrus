require "rails_helper"

RSpec.describe WorkEngineReconcilerActivityPruneJob do
  it "deletes reconciler activity events older than the retention window" do
    travel_to Time.zone.parse("2026-08-09 12:00:00 UTC") do
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "run_finished",
        source: "spec",
        message: "old",
        occurred_at: (WorkEngineReconcilerActivityEvent.retention_window + 1.second).ago
      )
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "run_finished",
        source: "spec",
        message: "fresh",
        occurred_at: WorkEngineReconcilerActivityEvent.retention_window.ago
      )
      # record! buffers; a reader flushes before querying, so the spec does too.
      Observability::EventSink.flush!(kinds: [ :work_engine_reconciler_activity ])

      expect { described_class.perform_now }.to change { WorkEngineReconcilerActivityEvent.count }.by(-1)

      expect(WorkEngineReconcilerActivityEvent.exists?(message: "old")).to be(false)
      expect(WorkEngineReconcilerActivityEvent.exists?(message: "fresh")).to be(true)
    end
  end

  it "is a no-op when retention is set to 0 (infinite)" do
    AppSetting.current.update!(work_engine_reconciler_activity_retention_days: 0)
    WorkEngineReconcilerActivityEvent.record!(
      event_type: "run_finished",
      source: "spec",
      message: "ancient",
      occurred_at: 10.years.ago
    )
    Observability::EventSink.flush!(kinds: [ :work_engine_reconciler_activity ])

    expect { described_class.perform_now }.not_to change { WorkEngineReconcilerActivityEvent.count }
  end

  it "does not archive before deleting when archive_before_delete is off (default, matches JOB-5025 behavior)" do
    travel_to Time.zone.parse("2026-08-09 12:00:00 UTC") do
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "run_finished",
        source: "spec",
        message: "old",
        occurred_at: (WorkEngineReconcilerActivityEvent.retention_window + 1.second).ago
      )
      Observability::EventSink.flush!(kinds: [ :work_engine_reconciler_activity ])

      expect { described_class.perform_now }.not_to change { RetentionArchive.count }
      expect(WorkEngineReconcilerActivityEvent.exists?(message: "old")).to be(false)
    end
  end

  it "archives before deleting when archive_before_delete is on" do
    AppSetting.current.update!(work_engine_reconciler_activity_archive_before_delete: true)

    travel_to Time.zone.parse("2026-08-09 12:00:00 UTC") do
      WorkEngineReconcilerActivityEvent.record!(
        event_type: "run_finished",
        source: "spec",
        message: "old",
        occurred_at: (WorkEngineReconcilerActivityEvent.retention_window + 1.second).ago
      )
      Observability::EventSink.flush!(kinds: [ :work_engine_reconciler_activity ])

      expect { described_class.perform_now }.to change { RetentionArchive.count }.by(1)

      archive = RetentionArchive.last
      expect(archive.retention_key).to eq("work_engine_reconciler_activity")
      expect(archive.row_count).to eq(1)
      expect(WorkEngineReconcilerActivityEvent.exists?(message: "old")).to be(false)
    end
  end
end
