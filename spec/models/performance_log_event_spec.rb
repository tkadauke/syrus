require "rails_helper"

RSpec.describe PerformanceLogEvent do
  describe ".expired" do
    it "includes events older than the retention window and excludes newer ones" do
      stale = described_class.create!(occurred_at: (described_class::RETENTION + 1.hour).ago, event_name: "sql", payload: {})
      fresh = described_class.create!(occurred_at: 1.hour.ago, event_name: "sql", payload: {})

      expect(described_class.expired).to include(stale)
      expect(described_class.expired).not_to include(fresh)
    end

    it "uses the occurred_at index instead of a full table scan" do
      plan = ActiveRecord::Base.connection.select_all(
        "EXPLAIN QUERY PLAN #{described_class.expired.to_sql}"
      ).to_a

      detail = plan.map { |row| row["detail"] }.join(" ")
      expect(detail).not_to match(/SCAN performance_log_events\z/)
    end
  end

  describe ".from_event_hash" do
    it "builds insertable attributes from a raw event hash" do
      attrs = described_class.from_event_hash(
        "occurred_at" => 1.minute.ago.iso8601,
        "event" => "sql.active_record",
        "fingerprint" => "SELECT 1",
        "sql" => "SELECT * FROM jobs",
        "top_sql_fingerprints" => [
          {
            "fingerprint" => "SELECT * FROM jobs WHERE id IN (?)",
            "sample_sql" => "SELECT * FROM jobs WHERE id IN (1, 2, 3)",
            "name" => "Job Load",
            "count" => 1,
            "total_duration_ms" => 300.0,
            "max_duration_ms" => 300.0
          }
        ]
      )

      expect(attrs[:event_name]).to eq("sql.active_record")
      expect(attrs[:sql_fingerprint]).to eq("SELECT 1")
      expect(attrs[:payload]).to be_a(Hash)
      expect(attrs[:payload]).to include("sql" => "SELECT * FROM jobs")
      expect(attrs[:payload].dig("top_sql_fingerprints", 0)).to include(
        "fingerprint" => "SELECT * FROM jobs WHERE id IN (?)",
        "sample_sql" => "SELECT * FROM jobs WHERE id IN (1, 2, 3)",
        "name" => "Job Load",
        "count" => 1
      )
    end

    it "round-trips slow job context through durable storage" do
      event = described_class.create!(
        described_class.from_event_hash(
          "occurred_at" => 1.minute.ago.iso8601,
          "event" => PerformanceLogging::SLOW_JOB_EVENT,
          "duration_ms" => 12_345.6,
          "trigger_reasons" => [ "duration", "sql_duration" ],
          "job_class" => "WorkEngine::ReconcileJob",
          "active_job_id" => "active-123",
          "provider_job_id" => "provider-456",
          "queue_name" => "control_plane",
          "priority" => 10,
          "executions" => 2,
          "arguments_count" => 1,
          "exception_class" => "ActiveRecord::QueryCanceled",
          "exception_message" => "query interrupted"
        )
      )

      expect(event.as_event_hash).to include(
        "event" => PerformanceLogging::SLOW_JOB_EVENT,
        "job_class" => "WorkEngine::ReconcileJob",
        "active_job_id" => "active-123",
        "provider_job_id" => "provider-456",
        "queue_name" => "control_plane",
        "priority" => 10,
        "executions" => 2,
        "arguments_count" => 1,
        "exception_class" => "ActiveRecord::QueryCanceled",
        "exception_message" => "query interrupted"
      )
    end
  end

  describe ".persist_observability_events!" do
    it "uses plain bulk inserts in batches instead of conflict-checking upserts" do
      rows = 2.times.map do |index|
        described_class.from_event_hash(
          "occurred_at" => (index + 1).minutes.ago.iso8601,
          "event" => PerformanceLogging::SLOW_SQL_EVENT,
          "path" => "/api/example/#{index}",
          "duration_ms" => 250 + index
        )
      end
      allow(described_class).to receive(:insert_all!).and_call_original

      described_class.persist_observability_events!(rows, batch_size: 1)

      expect(described_class).to have_received(:insert_all!).twice
      expect(described_class.order(:path).pluck(:path)).to eq([
        "/api/example/0",
        "/api/example/1"
      ])
    end

    it "normalizes sparse rows so batches can contain different payload shapes" do
      described_class.persist_observability_events!([
        described_class.from_event_hash(
          "occurred_at" => 1.minute.ago.iso8601,
          "event" => PerformanceLogging::SLOW_REQUEST_EVENT,
          "path" => "/api/with-path"
        ),
        described_class.from_event_hash(
          "occurred_at" => 2.minutes.ago.iso8601,
          "event" => PerformanceLogging::SLOW_JOB_EVENT,
          "job_class" => "PollInputSourceJob"
        ).except(:path)
      ], batch_size: 10)

      expect(described_class.count).to eq(2)
      expect(described_class.find_by(event_name: PerformanceLogging::SLOW_JOB_EVENT).path).to be_nil
    end
  end
end
