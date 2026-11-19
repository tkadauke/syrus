require "rails_helper"
require "yaml"

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

      expect(rows.fetch("fresh")).to include(cells: include(journaling_state: "Scheduled", spend_7d: "$4.75"))
      expect(rows.fetch("fresh")).not_to have_key(:tone)
      expect(rows.fetch("stale")).to include(tone: "critical", cells: include(journaling_state: "Auto-paused", journaling_age: "4d", unsaved_age: "7h"))
    end
  end

  it "localizes table copy, states, durations, and spend in every supported locale" do
    now = Time.zone.parse("2026-11-19 12:00:00 UTC")
    travel_to(now) do
      record_state("localized", "scheduled", at: now - 1.minute)
      record("syrus_coworkers_journaling_last_result_age_seconds", "localized", 2.days, at: now - 1.minute)
      record("syrus_coworkers_unsaved_workspace_age_seconds", "localized", 0, at: now - 1.minute)
      record_spend("localized", "chat", 1, at: now - 6.days)
      record_spend("localized", "chat", 5.75, at: now - 1.minute)

      summaries = %i[en de la].index_with { |locale| I18n.with_locale(locale) { described_class.build } }
      expect(summaries.values).to all(satisfy { |summary| summary.fetch(:label).exclude?("Translation missing") })

      german = summaries.fetch(:de)
      expect(german.fetch(:columns).pluck(:label)).to eq(
        [ "Coworker", "Journaling-Status", "Letztes Journal", "Ungespeicherter Workspace", "Ausgaben in 7 Tagen" ]
      )
      expect(german.fetch(:rows).sole.fetch(:cells)).to include(
        journaling_state: "Geplant", journaling_age: "2 T", unsaved_age: "Keine", spend_7d: "4,75 $"
      )
    end
  end

  it "keeps the dashboard translation keys and interpolation placeholders aligned" do
    trees = %w[en de la].index_with do |locale|
      YAML.load_file(Rails.root.join("plugins/coworkers/config/locales/#{locale}.yml"))
        .dig(locale, "api", "coworkers", "metrics_dashboard")
    end
    leaves = trees.transform_values { |tree| flatten_locale(tree) }
    english = leaves.fetch("en")

    expect(leaves.values.map { |entries| entries.keys.sort }.uniq.one?).to be(true)
    leaves.except("en").each_value do |entries|
      expect(entries.transform_values { |value| value.scan(/%\{([^}]+)\}/).flatten.sort })
        .to eq(english.transform_values { |value| value.scan(/%\{([^}]+)\}/).flatten.sort })
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

  def flatten_locale(value, prefix = [])
    return { prefix.join(".") => value } unless value.is_a?(Hash)

    value.each_with_object({}) do |(key, child), leaves|
      leaves.merge!(flatten_locale(child, prefix + [ key.to_s ]))
    end
  end
end
