module TestInsights
  class RecentStats
    EMPTY_STATS = {
      total_count: 0,
      failed_count: 0,
      passed_count: 0,
      failure_rate: 0.0,
      avg_duration_ms: nil
    }.freeze
    QUERY_BATCH_SIZE = 100

    def self.load(identities, lookback:)
      ids = identities.filter_map { |identity| Integer(identity.respond_to?(:id) ? identity.id : identity, exception: false) }.uniq
      stats_by_id = ids.index_with { EMPTY_STATS.dup }
      return stats_by_id if ids.empty?

      rows = PerformanceLogging.phase("test_insights.recent_stats", identity_count: ids.size) do
        ids.each_slice(QUERY_BATCH_SIZE).flat_map do |slice|
          TestCase.connection.select_rows(recent_cases_sql(slice, lookback: lookback))
        end
      end

      rows.group_by { |row| row.first.to_i }.each do |identity_id, grouped_rows|
        stats_by_id[identity_id] = stats_for(grouped_rows)
      end

      stats_by_id
    end

    def self.recent_cases_sql(ids, lookback:)
      union_sql = ids.map do |identity_id|
        recent_case_sql(identity_id, lookback: lookback)
      end.join(" UNION ALL ")

      <<~SQL.squish
        SELECT test_identity_id, status, duration_ms
        FROM (#{union_sql}) test_cases
      SQL
    end

    def self.recent_case_sql(identity_id, lookback:)
      table = TestCase.quoted_table_name
      identity_column = TestCase.connection.quote_column_name(:test_identity_id)
      created_column = TestCase.connection.quote_column_name(:created_at)
      id_column = TestCase.connection.quote_column_name(:id)
      wip_repair_failure_column = TestCase.connection.quote_column_name(:wip_repair_failure)

      <<~SQL.squish
        SELECT *
        FROM (
          SELECT #{table}.#{identity_column}, #{table}.status, #{table}.duration_ms
          FROM #{table}#{TestCase.scored_created_index_hint}
          WHERE #{table}.#{identity_column} = #{identity_id.to_i}
            AND #{table}.#{wip_repair_failure_column} = #{TestCase.connection.quoted_false}
          ORDER BY #{table}.#{created_column} DESC, #{table}.#{id_column} DESC
          LIMIT #{lookback.to_i}
        ) #{table}
      SQL
    end

    def self.stats_for(rows)
      total = rows.size
      failed = rows.count { |_identity_id, status, _duration| status == "failed" || status == "error" }
      passed = rows.count { |_identity_id, status, _duration| status == "passed" }
      durations = rows.filter_map { |_identity_id, _status, duration| Integer(duration, exception: false) }

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
