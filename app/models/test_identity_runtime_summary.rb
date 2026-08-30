class TestIdentityRuntimeSummary < ApplicationRecord
  ALL_GRADERS = "__all__".freeze
  RECENT_100_WINDOW = "recent_100".freeze
  WINDOW_SIZE = 100

  belongs_to :repository
  belongs_to :test_identity

  validates :grader_name, :window, presence: true
  validates :sample_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :avg_duration_ms, :p50_duration_ms, :p95_duration_ms, :min_duration_ms, :max_duration_ms,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  class << self
    def refresh_many!(identity_ids)
      identity_ids = Array(identity_ids).compact.uniq
      return if identity_ids.empty?

      identities = TestIdentity.where(id: identity_ids).pluck(:id, :repository_id).to_h
      return if identities.empty?

      delete_stale_summaries!(identities.keys)
      rows = summary_rows(identities)
      upsert_all(rows, unique_by: "idx_test_runtime_summary_identity_grader_window") if rows.any?
    end

    private

    def delete_stale_summaries!(identity_ids)
      where(test_identity_id: identity_ids, window: RECENT_100_WINDOW).delete_all
    end

    def summary_rows(identities)
      now = Time.current
      grouped_duration_rows(identities.keys).map do |(identity_id, grader_name), rows|
        durations = rows.map { |row| row.fetch(:duration_ms) }.sort
        next if durations.empty?

        {
          repository_id: identities.fetch(identity_id),
          test_identity_id: identity_id,
          grader_name: grader_name,
          window: RECENT_100_WINDOW,
          sample_count: durations.size,
          avg_duration_ms: (durations.sum.to_f / durations.size).round,
          p50_duration_ms: percentile(durations, 0.50),
          p95_duration_ms: percentile(durations, 0.95),
          min_duration_ms: durations.first,
          max_duration_ms: durations.last,
          last_observed_at: rows.map { |row| row.fetch(:created_at) }.max,
          created_at: now,
          updated_at: now
        }
      end.compact
    end

    def grouped_duration_rows(identity_ids)
      rows = bounded_duration_rows(identity_ids)
      grouped = Hash.new { |hash, key| hash[key] = [] }

      rows.each do |row|
        identity_id = row.fetch(:test_identity_id)
        grouped[[ identity_id, row.fetch(:grader_name) ]] << row if row.fetch(:grader_rank) <= WINDOW_SIZE
        grouped[[ identity_id, ALL_GRADERS ]] << row if row.fetch(:all_rank) <= WINDOW_SIZE
      end

      grouped
    end

    def bounded_duration_rows(identity_ids)
      ranked_cases = TestCase
        .joins(:test_run)
        .where(test_identity_id: identity_ids)
        .where.not(duration_ms: nil)
        .select(
          "test_cases.test_identity_id",
          "test_runs.grader_name",
          "test_cases.duration_ms",
          "test_cases.created_at",
          "ROW_NUMBER() OVER (PARTITION BY test_cases.test_identity_id, test_runs.grader_name ORDER BY test_cases.created_at DESC, test_cases.id DESC) AS syrus_grader_rank",
          "ROW_NUMBER() OVER (PARTITION BY test_cases.test_identity_id ORDER BY test_cases.created_at DESC, test_cases.id DESC) AS syrus_all_rank"
        )

      TestCase
        .from("(#{ranked_cases.to_sql}) test_cases")
        .where("syrus_grader_rank <= ? OR syrus_all_rank <= ?", WINDOW_SIZE, WINDOW_SIZE)
        .pluck(:test_identity_id, :grader_name, :duration_ms, :created_at, :syrus_grader_rank, :syrus_all_rank)
        .map do |test_identity_id, grader_name, duration_ms, created_at, grader_rank, all_rank|
          {
            test_identity_id: test_identity_id,
            grader_name: grader_name,
            duration_ms: duration_ms,
            created_at: created_at,
            grader_rank: grader_rank,
            all_rank: all_rank
          }
        end
    end

    def percentile(sorted_values, percentile)
      sorted_values[[ (sorted_values.size * percentile).ceil - 1, 0 ].max]
    end
  end
end
