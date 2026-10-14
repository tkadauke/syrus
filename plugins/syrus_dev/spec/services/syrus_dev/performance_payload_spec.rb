require "rails_helper"

RSpec.describe SyrusDev::PerformancePayload, requires_plugin: "syrus_dev" do
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    allow(SyrusVersion).to receive(:current).and_return("new-sha")
    Feature.where(slug: "performance_logging").delete_all
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    PerformanceLogging::Store.clear!
  end

  after do
    Current.reset
    PerformanceLogging::Store.clear!
  end

  it "does not count one slow query again through phase and slow SQL events" do
    fingerprint = "SELECT * FROM jobs WHERE id = ?"
    top_sql_fingerprint = {
      "fingerprint" => fingerprint,
      "sample_sql" => "SELECT * FROM jobs WHERE id = 1",
      "name" => "Job Load",
      "count" => 1,
      "total_duration_ms" => 120.0,
      "max_duration_ms" => 120.0
    }

    PerformanceLogging::Store.append(
      "event" => PerformanceLogging::SLOW_REQUEST_EVENT,
      "occurred_at" => Time.current.iso8601(6),
      "app_revision" => "new-sha",
      "method" => "GET",
      "path" => "/jobs/1",
      "controller" => "JobsController",
      "action" => "show",
      "duration_ms" => 1_500.0,
      "sql_count" => 1,
      "sql_duration_ms" => 120.0,
      "slow_sql_count" => 1,
      "top_sql_fingerprints" => [ top_sql_fingerprint ]
    )
    PerformanceLogging::Store.append(
      "event" => PerformanceLogging::SLOW_PHASE_EVENT,
      "occurred_at" => Time.current.iso8601(6),
      "app_revision" => "new-sha",
      "phase" => "render-job",
      "duration_ms" => 800.0,
      "sql_count" => 1,
      "sql_duration_ms" => 120.0,
      "slow_sql_count" => 1,
      "top_sql_fingerprints" => [ top_sql_fingerprint ]
    )
    PerformanceLogging::Store.append(
      "event" => PerformanceLogging::SLOW_SQL_EVENT,
      "occurred_at" => Time.current.iso8601(6),
      "app_revision" => "new-sha",
      "duration_ms" => 120.0,
      "name" => "Job Load",
      "sql" => "SELECT * FROM jobs WHERE id = 1",
      "fingerprint" => fingerprint
    )

    row = described_class.new.as_json.dig(:summaries, :sql_fingerprints).sole

    expect(row).to include(
      fingerprint: fingerprint,
      count: 1,
      total_duration_ms: 120.0,
      average_duration_ms: 120.0,
      max_duration_ms: 120.0
    )
  end
end
