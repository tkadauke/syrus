module TestInsights
  class RecentStats
    EMPTY_STATS = {
      total_count: 0,
      failed_count: 0,
      passed_count: 0,
      failure_rate: 0.0,
      avg_duration_ms: nil
    }.freeze

    def self.load(identities, lookback:)
      ids = identities.map(&:id)
      stats_by_id = ids.index_with { EMPTY_STATS.dup }
      return stats_by_id if ids.empty?

      ranked_cases = TestCase
        .where(test_identity_id: ids)
        .select(
          "test_cases.test_identity_id",
          "test_cases.status",
          "test_cases.duration_ms",
          "ROW_NUMBER() OVER (PARTITION BY test_cases.test_identity_id ORDER BY test_cases.created_at DESC, test_cases.id DESC) AS syrus_recent_rank"
        )

      rows = TestCase
        .from("(#{ranked_cases.to_sql}) test_cases")
        .where("syrus_recent_rank <= ?", lookback)
        .pluck(:test_identity_id, :status, :duration_ms)

      rows.group_by(&:first).each do |identity_id, grouped_rows|
        stats_by_id[identity_id] = stats_for(grouped_rows)
      end

      stats_by_id
    end

    def self.stats_for(rows)
      total = rows.size
      failed = rows.count { |_identity_id, status, _duration| status == "failed" || status == "error" }
      passed = rows.count { |_identity_id, status, _duration| status == "passed" }
      durations = rows.filter_map { |_identity_id, _status, duration| duration }

      {
        total_count: total,
        failed_count: failed,
        passed_count: passed,
        failure_rate: total.positive? ? (failed.to_f / total) : 0.0,
        avg_duration_ms: durations.any? ? (durations.sum.to_f / durations.size).round : nil
      }
    end
  end
end
