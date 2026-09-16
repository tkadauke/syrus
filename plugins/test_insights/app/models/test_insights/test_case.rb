module TestInsights
  class TestCase < ApplicationRecord
    self.table_name = "test_insight_cases"

    STATUSES = %w[passed failed skipped error].freeze
    FLAKINESS_LOOKBACK = 20
    CLASSIFICATION_SCORED = "scored".freeze
    CLASSIFICATION_WIP_REPAIR_FAILURE = "wip_repair_failure".freeze

    # test_insight_cases.name/suite_name/file_path and their test_insight_identities
    # counterparts are plain `t.string` columns (MySQL VARCHAR(255)). RSpec's full
    # example description (nested context + it-string, sometimes interpolated) can
    # exceed that, and raw insert_all!/insert_all bypass AR validations, so an
    # oversized value raises a DB-level error instead of failing a single record's
    # validation. Truncate defensively before any bulk insert touches these columns.
    # Fingerprinting must use the untruncated name/suite_name so identity keys stay
    # stable regardless of truncation -- see TestIdentity.fingerprint_for callers.
    MAX_STRING_COLUMN_BYTES = 255

    def self.truncate_string_column(value, max_bytes: MAX_STRING_COLUMN_BYTES)
      value.nil? ? nil : value.to_s.safe_byteslice(0, max_bytes)
    end

    belongs_to :test_run
    belongs_to :repository
    belongs_to :test_identity, optional: true

    validates :name, :suite_name, presence: true
    validates :status, presence: true, inclusion: { in: STATUSES }
    validates :duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

    scope :passed,  -> { where(status: "passed") }
    scope :failed,  -> { where(status: "failed") }
    scope :skipped, -> { where(status: "skipped") }
    scope :errored, -> { where(status: "error") }
    scope :failure_like, -> { where(status: %w[failed error]) }
    scope :wip_repair_failures, -> {
      joins(test_run: { run: :step })
        .failure_like
        .where.not(test_identity_id: nil)
        .where(steps: { kind: "grader" })
        .where.not(steps: { loop_id: nil })
        .where(later_passing_grader_case_exists_sql)
    }
    scope :scored, -> { where.not(id: wip_repair_failures.select(:id)) }

    # Returns flakiness data for a specific (repository, suite_name, name) tuple.
    # A test is flaky if it has both passed and failed within the lookback window.
    # Returns nil if no history exists.
    def self.flakiness_score(repository:, suite_name:, name:, lookback: FLAKINESS_LOOKBACK)
      statuses = history_scope_for(repository: repository, suite_name: suite_name, name: name)
        .scored
        .limit(lookback)
        .pluck(:status)

      return nil if statuses.empty?

      total  = statuses.size
      failed = statuses.count { |s| s == "failed" || s == "error" }
      passed = statuses.count { |s| s == "passed" }

      {
        score:        failed.to_f / total,
        failed_count: failed,
        total_count:  total,
        flaky:        failed > 0 && passed > 0,
        run_statuses: statuses.reverse # oldest to newest for sparkline
      }
    end

    # Returns avg, p50, p95 duration_ms for the lookback window.
    # Returns nil if no duration data exists.
    def self.runtime_percentiles(repository:, suite_name:, name:, lookback: FLAKINESS_LOOKBACK)
      durations = history_scope_for(repository: repository, suite_name: suite_name, name: name)
        .where.not(duration_ms: nil)
        .limit(lookback)
        .pluck(:duration_ms)

      return nil if durations.empty?

      sorted = durations.sort
      n      = sorted.size
      avg    = (sorted.sum.to_f / n).round
      p50    = sorted[[ (n * 0.5).ceil - 1, 0 ].max]
      p95    = sorted[[ (n * 0.95).ceil - 1, 0 ].max]

      { avg: avg, p50: p50, p95: p95 }
    end

    # Returns the top flakiest tests for a repository, sorted by flakiness score descending.
    # Only returns tests that have both passed and failed (truly flaky).
    def self.top_flaky_tests(repository:, lookback: FLAKINESS_LOOKBACK, limit: 20)
      lookback = lookback.to_i
      limit = limit.to_i
      TestIdentity.ensure_for_repository_later(repository) if TestIdentity.for_repository(repository).none?

      TestIdentity.for_repository(repository)
        .where.not(last_failed_at: nil)
        .where.not(last_passed_at: nil)
        .order(last_failed_at: :desc, last_passed_at: :desc, id: :desc)
        .limit(limit * 4)
        .filter_map do |identity|
          stats = lookback == TestIdentity::LIST_LOOKBACK ? identity.persisted_recent_stats : identity.recent_stats(lookback: lookback)
          total = stats.fetch(:total_count)
          failed = stats.fetch(:failed_count)
          next unless failed.positive? && stats.fetch(:passed_count).positive?

          {
            suite_name:       identity.suite_name,
            name:             identity.name,
            flakiness_score:  failed.to_f / total,
            failed_count:     failed,
            total_count:      total,
            avg_duration_ms:  stats.fetch(:avg_duration_ms),
            last_seen_at:     identity.last_seen_at
          }
        end
        .sort_by { |test| [ -test.fetch(:flakiness_score), -test.fetch(:failed_count), test.fetch(:suite_name), test.fetch(:name) ] }
        .first(limit)
    end

    # Batch-loads flakiness data for a set of test cases from a given repository.
    # Returns a hash keyed by [suite_name, name] => flakiness_data.
    def self.batch_flakiness(repository, test_cases_enum, lookback: FLAKINESS_LOOKBACK)
      cases = test_cases_enum.to_a
      return {} if cases.empty?

      result = batch_flakiness_by_identity(cases, lookback: lookback)
      fallback_cases = cases.select { |tc| tc.test_identity_id.blank? }
      return result if fallback_cases.empty?

      fallback_pairs = cases.select { |tc| tc.test_identity_id.blank? }.map { |tc| [ tc.suite_name, tc.name ] }.uniq
      condition = fallback_pairs.map { "(suite_name = ? AND name = ?)" }.join(" OR ")
      values = fallback_pairs.flat_map { |suite_name, name| [ suite_name, name ] }

      recent = where(repository_id: repository.id)
        .where(condition, *values)
        .scored
        .order(:suite_name, :name, created_at: :desc, id: :desc)
        .select(:suite_name, :name, :status, :duration_ms, :created_at)

      grouped = recent.group_by { |tc| [ tc.suite_name, tc.name ] }
      grouped.each do |pair, history|
        result[pair] = flakiness_for_history(history.first(lookback))
      end

      result
    end

    def self.history_scope_for(repository:, suite_name:, name:)
      identity = TestIdentity.find_by(
        repository_id: repository.id,
        fingerprint: TestIdentity.fingerprint_for(suite_name: suite_name, name: name)
      )
      return identity.test_cases.order(created_at: :desc, id: :desc) if identity

      # No TestIdentity matches this fingerprint, so there is nothing for
      # identity.test_cases above to have covered. Only fall back to matching
      # by raw suite_name/name among rows that were never linked to any
      # identity at all (pre-TestIdentity legacy rows) -- name is truncated to
      # fit VARCHAR(255), so matching it against rows that *do* have a linked
      # identity could silently merge two distinct long tests that share the
      # same 255-byte prefix.
      where(repository_id: repository.id, suite_name: suite_name, name: name, test_identity_id: nil)
        .order(created_at: :desc, id: :desc)
    end

    def self.batch_flakiness_by_identity(cases, lookback:)
      cases_by_identity_id = cases.filter_map { |tc| [ tc.test_identity_id, tc ] if tc.test_identity_id }.to_h
      return {} if cases_by_identity_id.empty?

      ranked_cases = where(test_identity_id: cases_by_identity_id.keys)
        .scored
        .select(
          "test_insight_cases.test_identity_id",
          "test_insight_cases.suite_name",
          "test_insight_cases.name",
          "test_insight_cases.status",
          "test_insight_cases.duration_ms",
          "test_insight_cases.created_at",
          "ROW_NUMBER() OVER (PARTITION BY test_insight_cases.test_identity_id ORDER BY test_insight_cases.created_at DESC, test_insight_cases.id DESC) AS syrus_flakiness_rank"
        )

      recent = from(ranked_cases, :test_insight_cases)
        .where("syrus_flakiness_rank <= ?", lookback)
        .order(:test_identity_id, created_at: :desc)
        .select(:test_identity_id, :suite_name, :name, :status, :duration_ms, :created_at)

      result = {}
      grouped = recent.group_by(&:test_identity_id)
      grouped.each do |identity_id, history|
        window = history.first(lookback)
        test_case = cases_by_identity_id.fetch(identity_id)
        result[[ test_case.suite_name, test_case.name ]] = flakiness_for_history(window)
      end

      result
    end

    def self.flakiness_for_history(history)
      total  = history.size
      failed = history.count { |tc| tc.status == "failed" || tc.status == "error" }
      passed = history.count { |tc| tc.status == "passed" }

      {
        score:        failed.to_f / total,
        failed_count: failed,
        total_count:  total,
        flaky:        failed > 0 && passed > 0,
        run_statuses: history.reverse.map(&:status)
      }
    end

    def self.classifications_for(test_cases)
      cases = Array(test_cases)
      ids = cases.filter_map(&:id)
      return {} if ids.empty?

      wip_ids = wip_repair_failures.where(id: ids).pluck(:id).to_set
      ids.index_with do |id|
        wip_ids.include?(id) ? CLASSIFICATION_WIP_REPAIR_FAILURE : CLASSIFICATION_SCORED
      end
    end

    def self.classification_for(test_case)
      classifications_for([ test_case ]).fetch(test_case.id, CLASSIFICATION_SCORED)
    end

    def self.later_passing_grader_case_exists_sql
      <<~SQL.squish
        EXISTS (
          SELECT 1
          FROM test_insight_cases later_cases
          INNER JOIN test_insight_runs later_test_runs
            ON later_test_runs.id = later_cases.test_run_id
          INNER JOIN runs later_runs
            ON later_runs.id = later_test_runs.run_id
          INNER JOIN steps later_steps
            ON later_steps.id = later_runs.step_id
          WHERE later_cases.test_identity_id = test_insight_cases.test_identity_id
            AND later_cases.status = 'passed'
            AND later_test_runs.grader_name = test_insight_runs.grader_name
            AND later_steps.kind = 'grader'
            AND later_steps.workflow_id = steps.workflow_id
            AND later_steps.loop_id = steps.loop_id
            AND later_steps.iteration > steps.iteration
        )
      SQL
    end
  end
end
