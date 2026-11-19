require "rails_helper"

RSpec.describe Coworkers::MetricsDashboardSummary do
  include ActiveSupport::Testing::TimeHelpers

  it "preserves journaling state, highlights stale rows, and totals seven-day spend" do
    now = Time.zone.parse("2026-11-19 12:00:00 UTC")
    travel_to(now) do
      record_state("fresh", "scheduled", at: now - 1.minute)
      record_state("stale", "auto_paused", at: now - 1.minute)
      record("syrus_coworkers_journaling_last_result_age_seconds", "fresh", 2.hours, at: now - 1.minute)
      record("syrus_coworkers_journaling_last_result_age_seconds", "stale", 4.days, at: now - 1.minute)
      record("syrus_coworkers_unsaved_workspace_age_seconds", "fresh", 0, at: now - 1.minute)
      record("syrus_coworkers_unsaved_workspace_age_seconds", "stale", 7.hours, at: now - 1.minute)
      record_spend("fresh", "chat", 1, at: now - 6.days)
      record_spend("fresh", "chat", 4.5, at: now - 1.minute)
      record_spend("fresh", "background_run", 2, at: now - 6.days)
      record_spend("fresh", "background_run", 3.25, at: now - 1.minute)

      rows = described_class.build.fetch(:rows).index_by { |row| row.fetch(:key) }

      expect(rows.fetch("fresh")).to include(cells: include(journaling_state: "scheduled", spend_7d: "$4.75"))
      expect(rows.fetch("fresh")).not_to have_key(:tone)
      expect(rows.fetch("stale")).to include(tone: "critical", cells: include(journaling_state: "auto_paused", journaling_age: "4d", unsaved_age: "7h"))
    end
  end

  it "does not highlight owner-paused journaling at warning or critical thresholds" do
    now = Time.zone.parse("2026-11-19 12:00:00 UTC")
    travel_to(now) do
      record_state("paused", "paused", at: now - 1.minute)
      record("syrus_coworkers_journaling_last_result_age_seconds", "paused", 4.days, at: now - 1.minute)
      record("syrus_coworkers_unsaved_workspace_age_seconds", "paused", 0, at: now - 1.minute)

      expect(described_class.build.fetch(:rows).sole).not_to have_key(:tone)
    end
  end

  def record_state(handle, active_state, at:)
    %w[scheduled paused auto_paused].each do |state|
      record("syrus_coworkers_journaling_state", handle, state == active_state ? 1 : 0, at:, labels: { "state" => state })
    end
  end

  def record_spend(handle, source, value, at:)
    record("syrus_coworkers_spend_usd_total", handle, value, at:, labels: { "source" => source })
  end

  def record(metric, handle, value, at:, labels: {})
    all_labels = { "coworker" => handle }.merge(labels)
    MetricsDashboard::Sample.create!(metric:, labels: all_labels,
      series_key: MetricsDashboard::Sample.series_key_for(all_labels), value:, recorded_at: at)
  end
end
