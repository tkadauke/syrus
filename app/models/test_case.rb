class TestCase < ApplicationRecord
  STATUSES = %w[passed failed skipped error].freeze
  FLAKINESS_LOOKBACK = 20

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

  # Returns flakiness data for a specific (repository, suite_name, name) tuple.
  # A test is flaky if it has both passed and failed within the lookback window.
  # Returns nil if no history exists.
  def self.flakiness_score(repository:, suite_name:, name:, lookback: FLAKINESS_LOOKBACK)
    statuses = history_scope_for(repository: repository, suite_name: suite_name, name: name)
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
    if repository.test_identities.none? && where(repository_id: repository.id).exists?
      TestIdentity.ensure_for_repository!(repository, index_search: false)
    end

    repository.test_identities
      .where.not(last_failed_at: nil)
      .where.not(last_passed_at: nil)
      .order(last_failed_at: :desc, last_passed_at: :desc, id: :desc)
      .limit(limit * 4)
      .filter_map do |identity|
        stats = identity.recent_stats(lookback: lookback)
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

    where(repository_id: repository.id, suite_name: suite_name, name: name).order(created_at: :desc, id: :desc)
  end

  def self.batch_flakiness_by_identity(cases, lookback:)
    cases_by_identity_id = cases.filter_map { |tc| [ tc.test_identity_id, tc ] if tc.test_identity_id }.to_h
    return {} if cases_by_identity_id.empty?

    recent = where(test_identity_id: cases_by_identity_id.keys)
      .order(:test_identity_id, created_at: :desc, id: :desc)
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
end
