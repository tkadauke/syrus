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
    def refresh_many!(identity_ids, grader_names: nil)
      identity_ids = Array(identity_ids).compact.uniq
      return if identity_ids.empty?

      identities = TestIdentity.where(id: identity_ids).pluck(:id, :repository_id).to_h
      return if identities.empty?

      refreshed_grader_names = summary_grader_names(identities.keys, grader_names: grader_names)
      delete_stale_summaries!(identities.keys, refreshed_grader_names)
      rows = summary_rows(identities, refreshed_grader_names)
      upsert_all(rows, unique_by: "idx_test_runtime_summary_identity_grader_window") if rows.any?
    end

    private

    def summary_grader_names(identity_ids, grader_names:)
      names = Array(grader_names).compact_blank.uniq
      names = grader_names_for_identities(identity_ids) if names.empty?
      [ ALL_GRADERS, *names ].uniq
    end

    def grader_names_for_identities(identity_ids)
      TestCase
        .joins(:test_run)
        .where(test_identity_id: identity_ids)
        .distinct
        .pluck("test_runs.grader_name")
        .compact_blank
    end

    def delete_stale_summaries!(identity_ids, grader_names)
      where(test_identity_id: identity_ids, window: RECENT_100_WINDOW, grader_name: grader_names).delete_all
    end

    def summary_rows(identities, grader_names)
      now = Time.current
      identities.flat_map do |identity_id, repository_id|
        grader_names.filter_map do |grader_name|
          rows = bounded_duration_rows(identity_id, grader_name: grader_name)
          summary_row(
            repository_id: repository_id,
            test_identity_id: identity_id,
            grader_name: grader_name,
            rows: rows,
            now: now
          )
        end
      end
    end

    def summary_row(repository_id:, test_identity_id:, grader_name:, rows:, now:)
      durations = rows.map { |row| row.fetch(:duration_ms) }.sort
      return if durations.empty?

      {
        repository_id: repository_id,
        test_identity_id: test_identity_id,
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
    end

    def bounded_duration_rows(identity_id, grader_name:)
      scope = TestCase
        .joins(:test_run)
        .where(test_identity_id: identity_id)
        .where.not(duration_ms: nil)
      scope = scope.where(test_runs: { grader_name: grader_name }) unless grader_name == ALL_GRADERS

      scope
        .order(created_at: :desc, id: :desc)
        .limit(WINDOW_SIZE)
        .pluck(:duration_ms, :created_at)
        .map do |duration_ms, created_at|
          {
            duration_ms: duration_ms,
            created_at: created_at
          }
        end
    end

    def percentile(sorted_values, percentile)
      sorted_values[[ (sorted_values.size * percentile).ceil - 1, 0 ].max]
    end
  end
end
