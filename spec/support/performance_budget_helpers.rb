module PerformanceBudgetHelpers
  def capture_performance_budget
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA"
      next if payload[:cached]
      next unless payload[:sql].match?(/\A\s*(?:SELECT|WITH)\b/i)

      queries << payload[:sql].to_s.squish
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }

    {
      sql_count: queries.size,
      queries: queries,
      fingerprints: queries.map { |sql| fingerprint_sql_for_budget(sql) },
      payload_bytes: response.body.bytesize
    }
  end

  def expect_performance_budget(metrics, max_sql:, max_payload_bytes:, max_duplicate_fingerprints: 6, forbidden_sql: [])
    aggregate_failures "performance budget" do
      expect(metrics.fetch(:sql_count)).to be <= max_sql
      expect(metrics.fetch(:payload_bytes)).to be <= max_payload_bytes
      duplicate_fingerprints = metrics.fetch(:fingerprints).tally.select { |_fingerprint, count| count > max_duplicate_fingerprints }
      expect(duplicate_fingerprints).to be_empty

      Array(forbidden_sql).each do |pattern|
        expect(metrics.fetch(:queries).grep(pattern)).to be_empty
      end
    end
  end

  private

  def fingerprint_sql_for_budget(sql)
    sql
      .gsub(/'(?:[^']|'')*'/, "?")
      .gsub(/\b\d+\b/, "?")
      .gsub(/\s+/, " ")
      .strip
  end
end

RSpec.configure do |config|
  config.include PerformanceBudgetHelpers, type: :request
end
