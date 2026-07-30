class TestCase < ApplicationRecord
  STATUSES = %w[passed failed skipped error].freeze
  FLAKINESS_LOOKBACK = 20

  belongs_to :test_run
  belongs_to :repository

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
    statuses = where(repository_id: repository.id, suite_name: suite_name, name: name)
      .order(created_at: :desc)
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
    durations = where(repository_id: repository.id, suite_name: suite_name, name: name)
      .where.not(duration_ms: nil)
      .order(created_at: :desc)
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
    sql = <<~SQL
      WITH ranked AS (
        SELECT suite_name, name, status, duration_ms, created_at,
               ROW_NUMBER() OVER (PARTITION BY suite_name, name ORDER BY created_at DESC) AS rn
        FROM test_cases
        WHERE repository_id = :repository_id
      ),
      stats AS (
        SELECT
          suite_name,
          name,
          COUNT(*) AS total_count,
          SUM(CASE WHEN status IN ('failed', 'error') THEN 1 ELSE 0 END) AS failed_count,
          SUM(CASE WHEN status = 'passed' THEN 1 ELSE 0 END) AS passed_count,
          AVG(CAST(duration_ms AS REAL)) AS avg_duration_ms,
          MAX(created_at) AS last_seen_at
        FROM ranked
        WHERE rn <= :lookback
        GROUP BY suite_name, name
        HAVING SUM(CASE WHEN status IN ('failed', 'error') THEN 1 ELSE 0 END) > 0
           AND SUM(CASE WHEN status = 'passed' THEN 1 ELSE 0 END) > 0
      )
      SELECT
        suite_name,
        name,
        total_count,
        failed_count,
        avg_duration_ms,
        last_seen_at
      FROM stats
      ORDER BY failed_count * 1.0 / total_count DESC
      LIMIT :limit
    SQL

    rows = connection.exec_query(
      sanitize_sql([ sql, { repository_id: repository.id, lookback: lookback, limit: limit } ])
    )

    rows.map do |row|
      total  = row["total_count"].to_i
      failed = row["failed_count"].to_i
      {
        suite_name:       row["suite_name"],
        name:             row["name"],
        flakiness_score:  failed.to_f / total,
        failed_count:     failed,
        total_count:      total,
        avg_duration_ms:  row["avg_duration_ms"]&.round,
        last_seen_at:     row["last_seen_at"]
      }
    end
  end

  # Batch-loads flakiness data for a set of test cases from a given repository.
  # Returns a hash keyed by [suite_name, name] => flakiness_data.
  def self.batch_flakiness(repository, test_cases_enum, lookback: FLAKINESS_LOOKBACK)
    pairs = test_cases_enum.map { |tc| [ tc.suite_name, tc.name ] }.uniq
    return {} if pairs.empty?

    condition = pairs.map { "(suite_name = ? AND name = ?)" }.join(" OR ")
    values    = pairs.flat_map { |s, n| [ s, n ] }

    recent = where(repository_id: repository.id)
      .where(condition, *values)
      .order(:suite_name, :name, created_at: :desc)
      .select(:suite_name, :name, :status, :duration_ms, :created_at)

    grouped = recent.group_by { |tc| [ tc.suite_name, tc.name ] }

    result = {}
    grouped.each do |(suite, name), cases|
      window = cases.first(lookback)
      total  = window.size
      failed = window.count { |tc| tc.status == "failed" || tc.status == "error" }
      passed = window.count { |tc| tc.status == "passed" }

      result[[ suite, name ]] = {
        score:        failed.to_f / total,
        failed_count: failed,
        total_count:  total,
        flaky:        failed > 0 && passed > 0,
        run_statuses: window.reverse.map(&:status)
      }
    end

    result
  end
end
