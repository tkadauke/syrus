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

  it "reports and queries within the configured retention window" do
    set_retention(:performance_log_event, 12)
    PerformanceLogEvent.create!(
      occurred_at: 13.hours.ago,
      event_name: PerformanceLogging::SLOW_REQUEST_EVENT,
      app_revision: "too-old-sha",
      payload: { "duration_ms" => 1_000.0, "path" => "/too-old" }
    )
    PerformanceLogEvent.create!(
      occurred_at: 11.hours.ago,
      event_name: PerformanceLogging::SLOW_REQUEST_EVENT,
      app_revision: "old-sha",
      payload: { "duration_ms" => 1_000.0, "path" => "/retained" }
    )

    payload = described_class.new(params: { revision_scope: "all" }).as_json

    expect(payload.dig(:storage, :expires_in_seconds)).to eq(12.hours.to_i)
    expect(payload.dig(:baseline, :revision)).to eq("old-sha")
  end

  it "summarizes a slow query even when its request stays below request thresholds" do
    fingerprint = "SELECT * FROM jobs WHERE id = ?"

    PerformanceLogging::Store.append(
      "event" => PerformanceLogging::SLOW_SQL_EVENT,
      "occurred_at" => Time.current.iso8601(6),
      "app_revision" => "new-sha",
      "duration_ms" => 42.0,
      "name" => "Job Load",
      "sql" => "SELECT * FROM jobs WHERE id = 1",
      "fingerprint" => fingerprint
    )

    row = described_class.new.as_json.dig(:summaries, :sql_fingerprints).sole

    expect(row).to include(
      fingerprint: fingerprint,
      sample_sql: "SELECT * FROM jobs WHERE id = 1",
      name: "Job Load",
      count: 1,
      total_duration_ms: 42.0,
      average_duration_ms: 42.0,
      max_duration_ms: 42.0
    )
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

  it "reports input latency component distributions" do
    [
      { "input_delay_ms" => "10", "processing_duration_ms" => "20", "presentation_delay_ms" => "30" },
      { "input_delay_ms" => "30", "processing_duration_ms" => "40", "presentation_delay_ms" => "50" }
    ].each_with_index do |metadata, index|
      PerformanceLogging::Store.append(
        "event" => PerformanceLogging::BROWSER_TRACE_EVENT,
        "occurred_at" => (Time.current + index.seconds).iso8601(6),
        "app_revision" => "new-sha",
        "name" => "browser.input_latency",
        "path" => "/jobs/1",
        "duration_ms" => index.zero? ? 60.0 : 120.0,
        "metadata" => metadata
      )
    end

    row = described_class.new.as_json.dig(:summaries, :browser_traces).sole
    expect(row).to include(
      average_input_delay_ms: 20.0,
      max_input_delay_ms: 30.0,
      average_processing_duration_ms: 30.0,
      max_processing_duration_ms: 40.0,
      average_presentation_delay_ms: 40.0,
      max_presentation_delay_ms: 50.0
    )
  end
end
