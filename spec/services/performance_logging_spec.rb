require "rails_helper"

RSpec.describe PerformanceLogging do
  let(:cache_store) { ActiveSupport::Cache::MemoryStore.new }

  before do
    allow(Rails).to receive(:cache).and_return(cache_store)
    allow(Rails.logger).to receive(:info)
    allow(SyrusVersion).to receive(:current).and_return("sha-current")
    Feature.where(slug: "performance_logging").delete_all
    Current.reset
    described_class::Store.clear!
  end

  after do
    described_class::Store.clear!
    Current.reset
  end

  it "stays disabled unless the feature gate is enabled" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: false)
    Current.reset

    described_class.record_sql({ name: "Job Load", sql: "SELECT * FROM jobs" }, 500)

    expect(described_class::Store.recent).to be_empty
    expect(Rails.logger).not_to have_received(:info)
  end

  it "records slow SQL events to logs and the recent-event buffer" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_sql_threshold_ms).and_return(1.0)

    described_class.with_request_context(request_id: "req-123", method: "GET", path: "/jobs", user_id: 7, admin: true) do
      described_class.record_sql(
        { name: "Job Load", sql: "SELECT *\nFROM jobs\nWHERE title = 'é' AND id = 42" },
        5.25
      )
    end

    event = described_class::Store.recent.first
    expect(event).to include(
      "event" => "syrus.performance.slow_sql",
      "app_revision" => "sha-current",
      "request_id" => "req-123",
      "path" => "/jobs",
      "user_id" => 7,
      "admin" => true,
      "duration_ms" => 5.3,
      "name" => "Job Load",
      "sql" => "SELECT * FROM jobs WHERE title = 'é' AND id = 42",
      "fingerprint" => "SELECT * FROM jobs WHERE title = ? AND id = ?"
    )
    expect(event["sql"].encoding).to eq(Encoding::UTF_8)
    expect(Rails.logger).to have_received(:info).with(/syrus\.performance\.slow_sql/)
  end

  it "does not record observability table writes as slow SQL" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_sql_threshold_ms).and_return(1.0)

    described_class.record_sql(
      {
        name: "PerformanceLogEvent Bulk Insert",
        sql: "INSERT INTO `performance_log_events` (`occurred_at`, `event_name`) VALUES ('2026-08-16', 'slow')"
      },
      5_000.0
    )

    expect(described_class::Store.recent).to be_empty
    expect(Rails.logger).not_to have_received(:info)
  end

  it "does not record operational log FTS maintenance as slow SQL" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_sql_threshold_ms).and_return(1.0)

    described_class.record_sql(
      {
        name: "OperationalLogIndex Delete Many",
        sql: "DELETE FROM operational_log_fts WHERE operational_log_event_id IN (1, 2, 3)"
      },
      750.0
    )

    expect(described_class::Store.recent).to be_empty
    expect(Rails.logger).not_to have_received(:info)
  end

  it "records slow request events with SQL counters and top SQL fingerprints" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_request_threshold_ms).and_return(1.0)
    allow(described_class).to receive(:slow_sql_threshold_ms).and_return(1_000.0)

    described_class.with_request_context(request_id: "req-abc", path: "/dashboard/jobs?view=list", user_id: 9) do
      described_class.record_sql({ name: "Job Load", sql: "SELECT * FROM jobs WHERE id = 1" }, 20.0)
      described_class.record_sql({ name: "Job Load", sql: "SELECT * FROM jobs WHERE id = 2" }, 22.25)
      described_class.record_sql({ name: "Run Count", sql: "SELECT COUNT(*) FROM runs" }, 8.0)
    end

    described_class.record_request(
      {
        request_id: "req-abc",
        method: "GET",
        path: "/dashboard/jobs?view=list",
        controller: "Api::V1::App::DashboardController",
        action: "show",
        format: "json",
        status: 200,
        view_runtime: 1.2,
        db_runtime: 42.25
      },
      1_500.25
    )

    event = described_class::Store.recent.first
    expect(event).to include(
      "event" => "syrus.performance.slow_request",
      "request_id" => "req-abc",
      "duration_ms" => 1_500.3,
      "path" => "/dashboard/jobs?view=list",
      "trigger_reasons" => [ "duration" ],
      "sql_count" => 3,
      "sql_duration_ms" => 50.3,
      "slow_sql_count" => 0
    )
    expect(event["top_sql_fingerprints"].first).to include(
      "fingerprint" => "SELECT * FROM jobs WHERE id = ?",
      "count" => 2,
      "total_duration_ms" => 42.3,
      "max_duration_ms" => 22.3
    )
  end

  it "records SQL-heavy requests even when the request is below the slow duration threshold" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_request_threshold_ms).and_return(1_000.0)
    allow(described_class).to receive(:request_sql_count_threshold).and_return(2)
    allow(described_class).to receive(:request_sql_duration_threshold_ms).and_return(25.0)
    allow(described_class).to receive(:slow_sql_threshold_ms).and_return(1_000.0)

    described_class.with_request_context(request_id: "req-sql-heavy", path: "/api/v1/app/dashboard") do
      described_class.record_sql({ name: "Job Load", sql: "SELECT * FROM jobs WHERE id = 1" }, 20.0)
      described_class.record_sql({ name: "Run Load", sql: "SELECT * FROM runs WHERE id = 2" }, 10.0)
    end

    described_class.record_request(
      {
        request_id: "req-sql-heavy",
        method: "GET",
        path: "/api/v1/app/dashboard",
        controller: "Api::V1::App::DashboardController",
        action: "show",
        format: "json",
        status: 200
      },
      120.0
    )

    event = described_class::Store.recent.first
    expect(event).to include(
      "event" => "syrus.performance.slow_request",
      "request_id" => "req-sql-heavy",
      "duration_ms" => 120.0,
      "trigger_reasons" => [ "sql_count", "sql_duration" ],
      "sql_count" => 2,
      "sql_duration_ms" => 30.0
    )
  end

  it "records slow ActiveJob events with isolated SQL counters and sanitized job context" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_job_threshold_ms).and_return(0.0)
    allow(described_class).to receive(:slow_sql_threshold_ms).and_return(1_000.0)

    job_class = Class.new(ApplicationJob) do
      queue_as :polling

      def perform(*)
        PerformanceLogging.record_sql({ name: "Job Load", sql: "SELECT * FROM jobs WHERE state = 'open'" }, 25.0)
      end
    end
    stub_const("SlowPerformanceJob", job_class)

    SlowPerformanceJob.perform_now("raw arguments are not logged")

    event = described_class::Store.recent.find { |row| row["event"] == "syrus.performance.slow_job" }
    expect(event).to include(
      "event" => "syrus.performance.slow_job",
      "job_class" => "SlowPerformanceJob",
      "queue_name" => "polling",
      "trigger_reasons" => [ "duration" ],
      "sql_count" => 1,
      "sql_duration_ms" => 25.0,
      "slow_sql_count" => 0,
      "arguments_count" => 1
    )
    expect(event["active_job_id"]).to be_present
    expect(event.to_s).not_to include("raw arguments are not logged")
    expect(event["top_sql_fingerprints"].first).to include(
      "fingerprint" => "SELECT * FROM jobs WHERE state = ?",
      "total_duration_ms" => 25.0
    )
    expect(Current.performance_request_context).to be_nil
    expect(Current.performance_sql_count).to be_nil
  end

  it "records SQL-heavy ActiveJob events even below the job duration threshold" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_job_threshold_ms).and_return(1_000.0)
    allow(described_class).to receive(:request_sql_count_threshold).and_return(2)
    allow(described_class).to receive(:request_sql_duration_threshold_ms).and_return(25.0)
    allow(described_class).to receive(:slow_sql_threshold_ms).and_return(1_000.0)

    job_class = Class.new(ApplicationJob) do
      def perform
        PerformanceLogging.record_sql({ name: "Job Load", sql: "SELECT * FROM jobs WHERE id = 1" }, 15.0)
        PerformanceLogging.record_sql({ name: "Run Load", sql: "SELECT * FROM runs WHERE id = 2" }, 12.0)
      end
    end
    stub_const("SqlHeavyPerformanceJob", job_class)

    SqlHeavyPerformanceJob.perform_now

    event = described_class::Store.recent.find { |row| row["event"] == "syrus.performance.slow_job" }
    expect(event).to include(
      "job_class" => "SqlHeavyPerformanceJob",
      "trigger_reasons" => [ "sql_count", "sql_duration" ],
      "sql_count" => 2,
      "sql_duration_ms" => 27.0
    )
  end

  it "does not record the performance diagnostics endpoint as a slow request" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_request_threshold_ms).and_return(1.0)

    described_class.record_request(
      {
        method: "GET",
        path: "/api/v1/app/admin/performance?revision_scope=all",
        controller: "Api::V1::App::Admin::PerformanceController",
        action: "show",
        format: "json",
        status: 200
      },
      1_500.0
    )

    expect(described_class::Store.recent).to be_empty
  end

  it "does not record the performance diagnostics SPA page as a slow request" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_request_threshold_ms).and_return(1.0)

    described_class.record_request(
      {
        method: "GET",
        path: "/admin/performance",
        controller: "SpaController",
        action: "show",
        format: "html",
        status: 200
      },
      1_500.0
    )

    expect(described_class::Store.recent).to be_empty
  end

  it "records slow phase events with safe metadata" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_phase_threshold_ms).and_return(0.0)

    described_class.with_request_context(request_id: "req-phase", path: "/dashboard") do
      described_class.phase("dashboard_payload", subject: "job", view: "list") do
        described_class.record_sql({ name: "Job Load", sql: "SELECT * FROM jobs WHERE state = 'open'" }, 12.0)
        "done"
      end
    end

    event = described_class::Store.recent.first
    expect(event).to include(
      "event" => "syrus.performance.slow_phase",
      "request_id" => "req-phase",
      "path" => "/dashboard",
      "phase" => "dashboard_payload",
      "metadata" => { "subject" => "job", "view" => "list" },
      "sql_count" => 1,
      "sql_duration_ms" => 12.0,
      "slow_sql_count" => 0
    )
    expect(event["top_sql_fingerprints"].first).to include(
      "fingerprint" => "SELECT * FROM jobs WHERE state = ?",
      "sample_sql" => "SELECT * FROM jobs WHERE state = 'open'",
      "name" => "Job Load",
      "count" => 1,
      "total_duration_ms" => 12.0
    )
  end

  it "records nested phase SQL as parent total and child self" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    allow(described_class).to receive(:slow_phase_threshold_ms).and_return(0.0)
    allow(described_class).to receive(:slow_sql_threshold_ms).and_return(1.0)

    described_class.with_request_context(request_id: "req-nested", path: "/admin/performance") do
      described_class.phase("admin_payload") do
        described_class.phase("admin_payload.sql_summary") do
          described_class.record_sql({ name: "Job Load", sql: "SELECT * FROM jobs WHERE state = 'open'" }, 12.0)
        end
      end
    end

    events = described_class::Store.recent.select { |event| event["event"] == "syrus.performance.slow_phase" }
    parent = events.find { |event| event["phase"] == "admin_payload" }
    child = events.find { |event| event["phase"] == "admin_payload.sql_summary" }

    expect(parent).to include(
      "sql_count" => 1,
      "sql_duration_ms" => 12.0,
      "slow_sql_count" => 1,
      "self_sql_count" => 0,
      "self_sql_duration_ms" => 0.0,
      "self_slow_sql_count" => 0
    )
    expect(child).to include(
      "sql_count" => 1,
      "sql_duration_ms" => 12.0,
      "slow_sql_count" => 1,
      "self_sql_count" => 1,
      "self_sql_duration_ms" => 12.0,
      "self_slow_sql_count" => 1
    )
    expect(parent["top_sql_fingerprints"]).to eq([])
    expect(parent["self_top_sql_fingerprints"]).to eq([])
    expect(child["top_sql_fingerprints"].first).to include(
      "fingerprint" => "SELECT * FROM jobs WHERE state = ?",
      "count" => 1,
      "total_duration_ms" => 12.0
    )
    expect(child["self_top_sql_fingerprints"]).to eq(child["top_sql_fingerprints"])
    slow_sql = described_class::Store.recent.find { |event| event["event"] == "syrus.performance.slow_sql" }
    expect(slow_sql).to include(
      "phase" => "admin_payload.sql_summary",
      "fingerprint" => "SELECT * FROM jobs WHERE state = ?"
    )
  end

  it "records browser trace spans" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset

    described_class.record_browser_trace(
      trace_id: "trace-dashboard",
      name: "dashboard.route",
      path: "/dashboard/jobs",
      duration_ms: 350.0,
      visibility_state: "visible",
      spans: [
        { name: "api.dashboard.rows", duration_ms: 120.25, started_at_ms: 10.0 },
        { name: "frontend.after_api", duration_ms: 229.75, metadata: { api_request_count: 1 } }
      ]
    )

    event = described_class::Store.recent.first
    expect(event).to include(
      "event" => "syrus.performance.browser_trace",
      "trace_id" => "trace-dashboard",
      "name" => "dashboard.route"
    )
    expect(event["spans"]).to eq([
      { "name" => "api.dashboard.rows", "duration_ms" => 120.3, "started_at_ms" => 10.0 },
      { "name" => "frontend.after_api", "duration_ms" => 229.8, "metadata" => { "api_request_count" => "1" } }
    ])
  end

  it "does not flush the admin buffer to Rails.cache on every event" do
    Feature.create!(slug: "performance_logging", category: "Operations", name: "Performance logging", enabled: true)
    Current.reset
    described_class::Store.clear!
    allow(described_class).to receive(:slow_phase_threshold_ms).and_return(0.0)
    allow(cache_store).to receive(:write).and_call_original

    3.times do |index|
      described_class.phase("phase-#{index}") { "done" }
    end

    expect(described_class::Store.recent.size).to eq(3)
    expect(cache_store).not_to have_received(:write)
  end

  # Production pollers died with Regexp::TimeoutError raised out of
  # instrumentation (PollInputSourceJob, PollExternalOpenPrsJob): safe_string
  # collapsed whitespace across the *whole* value before truncating, so one
  # oversized SQL statement made the regexp engine walk megabytes and took
  # the surrounding job down with it.
  #
  describe ".safe_string" do
    it "does not scan beyond a bounded prefix of a huge value" do
      scan_limit = 600 * described_class::SAFE_STRING_SCAN_HEADROOM
      giant = "#{'a b ' * 1_000}#{' ' * scan_limit}TRAILING_MARKER"
      expect(giant.bytesize).to be > scan_limit

      result = described_class.safe_string(giant, 600)
      expect(result.bytesize).to be <= 600
      expect(result).not_to include("TRAILING_MARKER")
    end

    it "truncates a huge value to the caller's limit" do
      giant = "a b " * 5_000_000

      expect(described_class.safe_string(giant, 600).bytesize).to be <= 600
    end

    it "still collapses whitespace and trims ordinary values" do
      expect(described_class.safe_string("  SELECT\n\t*  FROM   jobs  ", 600)).to eq("SELECT * FROM jobs")
    end

    it "leaves values shorter than the limit untouched" do
      expect(described_class.safe_string("SELECT 1", 600)).to eq("SELECT 1")
    end

    it "collapses runs of whitespace that fit inside the scan window" do
      padded = "SELECT 1#{' ' * 1_000}FROM jobs"

      expect(described_class.safe_string(padded, 600)).to eq("SELECT 1 FROM jobs")
    end

    # The headroom trades a little fidelity for a hard bound: a value padded
    # with more whitespace than the scan window loses whatever follows it.
    # These are instrumentation samples, not data, so a truncated sample beats
    # an unbounded scan.
    it "drops content past the scan window when padding exceeds it" do
      padded = "SELECT 1#{' ' * 5_000}FROM jobs"

      expect(described_class.safe_string(padded, 600)).to eq("SELECT 1")
    end
  end

  describe ".fingerprint_sql" do
    it "fingerprints an oversized statement without scanning all of it" do
      scan_limit = 4_000 * described_class::SAFE_STRING_SCAN_HEADROOM
      giant = "SELECT * FROM jobs WHERE id IN (#{Array.new(20_000) { '1' }.join(', ')}) #{' ' * scan_limit}TRAILING_MARKER"
      expect(giant.bytesize).to be > scan_limit

      fingerprint = described_class.fingerprint_sql(giant)

      expect(fingerprint).to start_with("SELECT * FROM jobs WHERE id IN (?")
      expect(fingerprint.bytesize).to be <= 1_000
      expect(fingerprint).not_to include("TRAILING_MARKER")
    end
  end
end
