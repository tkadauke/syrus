require "rails_helper"

RSpec.describe PerformanceLogEvent do
  describe ".expired" do
    it "includes events older than the retention window and excludes newer ones" do
      stale = described_class.create!(occurred_at: 7.hours.ago, event_name: "sql", payload: {})
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
      expect(attrs[:payload]).not_to have_key("sql")
      expect(attrs[:payload].dig("top_sql_fingerprints", 0)).to include(
        "fingerprint" => "SELECT * FROM jobs WHERE id IN (?)",
        "name" => "Job Load",
        "count" => 1
      )
      expect(attrs[:payload].dig("top_sql_fingerprints", 0)).not_to have_key("sample_sql")
    end
  end
end
