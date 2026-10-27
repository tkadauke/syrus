module PerformanceBudgetHelpers
  # Statements against the queue database are excluded from every SQL budget.
  #
  # The test environment runs single-database and does not load the Solid Queue
  # tables, so a readiness probe like AppApi::ReadinessChecks#worker_queue_check
  # either errors out before issuing a statement or issues one, depending on
  # whether something earlier in the same process happened to create those
  # tables. That made these budgets order-dependent: run alone, the bootstrap
  # endpoint measured 42 statements; run after its sibling request specs, 43 --
  # and the extra one was always
  # `SELECT COUNT(*) FROM solid_queue_processes WHERE kind = ?`. Two budgets
  # failed by exactly one statement that way, and between them they kept main
  # red and made every merge train pay to rediscover it.
  #
  # A budget on application reads should not move with the schema state of a
  # queue the endpoint only probes, so it does not count them.
  QUEUE_TABLE_SQL = /\bsolid_queue_/i

  def capture_performance_budget
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:name] == "SCHEMA"
      next if payload[:cached]
      next if payload[:sql].to_s.match?(QUEUE_TABLE_SQL)

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
