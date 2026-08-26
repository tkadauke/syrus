require "digest"

class TestIdentity < ApplicationRecord
  FINGERPRINT_SEPARATOR = "\0".freeze
  RECENT_FAILURE_WINDOW = 14.days
  HISTORY_LIMIT = 100
  LIST_LOOKBACK = 20
  INTERESTING_LIMIT = 10

  belongs_to :repository
  has_many :test_cases, dependent: :nullify

  validates :name, :suite_name, :fingerprint, presence: true
  validates :fingerprint, uniqueness: { scope: :repository_id }
  validates :last_status, inclusion: { in: TestCase::STATUSES }, allow_nil: true
  validates :last_duration_ms, numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true

  scope :search_by_name, ->(query) {
    pattern = "%#{sanitize_sql_like(query.to_s.strip)}%"
    where("test_identities.name LIKE ? OR test_identities.suite_name LIKE ? OR test_identities.file_path LIKE ?", pattern, pattern, pattern)
  }

  def self.fingerprint_for(suite_name:, name:)
    Digest::SHA256.hexdigest([ suite_name.to_s, name.to_s ].join(FINGERPRINT_SEPARATOR))
  end

  def self.ensure_for_cases!(repository:, cases:)
    attrs_by_fingerprint = {}
    cases.each do |test_case|
      fingerprint = fingerprint_for(suite_name: test_case.suite_name, name: test_case.name)
      attrs_by_fingerprint[fingerprint] ||= {
        repository_id: repository.id,
        fingerprint: fingerprint,
        suite_name: test_case.suite_name,
        name: test_case.name,
        file_path: test_case.file_path,
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    return {} if attrs_by_fingerprint.empty?

    existing = where(repository_id: repository.id, fingerprint: attrs_by_fingerprint.keys).index_by(&:fingerprint)
    missing_attrs = attrs_by_fingerprint.except(*existing.keys).values

    if missing_attrs.any?
      begin
        insert_all(missing_attrs)
      rescue ActiveRecord::RecordNotUnique
        # Another worker may have created the durable identity concurrently.
      end
    end

    where(repository_id: repository.id, fingerprint: attrs_by_fingerprint.keys).index_by(&:fingerprint)
  end

  def self.ensure_for_repository!(repository, index_search: true)
    rows = TestCase
      .where(repository_id: repository.id, test_identity_id: nil)
      .select(:id, :suite_name, :name, :file_path)
      .limit(20_000)
      .to_a
    return if rows.empty?

    identities = ensure_for_cases!(repository: repository, cases: rows)
    rows.group_by { |test_case| fingerprint_for(suite_name: test_case.suite_name, name: test_case.name) }.each do |fingerprint, test_cases|
      identity = identities[fingerprint]
      next unless identity

      TestCase.where(id: test_cases.map(&:id)).update_all(test_identity_id: identity.id, updated_at: Time.current)
    end

    refresh_many!(identities.values.map(&:id))
    TestIdentitySearchIndex.upsert_many(where(id: identities.values.map(&:id)).includes(:repository)) if index_search
  end

  def self.refresh_many!(ids)
    ids = Array(ids).compact.uniq
    return if ids.empty?

    latest_by_identity_id = latest_cases_for(ids).index_by(&:test_identity_id)
    failed_at_by_identity_id = latest_status_at_for(ids, %w[failed error])
    passed_at_by_identity_id = latest_status_at_for(ids, "passed")
    now = Time.current

    updates = {}
    where(id: ids).find_each do |identity|
      latest = latest_by_identity_id[identity.id]
      next unless latest

      updates[identity.id] = {
        last_status: latest.status,
        last_seen_at: latest.created_at,
        last_failed_at: failed_at_by_identity_id[identity.id],
        last_passed_at: passed_at_by_identity_id[identity.id],
        last_duration_ms: latest.duration_ms,
        file_path: identity.file_path.presence || latest.file_path,
        updated_at: now
      }
    end
    bulk_update_summary_columns!(updates)
  end

  def self.latest_cases_for(ids)
    ids = Array(ids).filter_map { |id| Integer(id, exception: false) }.uniq
    return [] if ids.empty?

    TestCase.find_by_sql([
      <<~SQL.squish,
        SELECT *
        FROM (
          SELECT
            test_cases.*,
            ROW_NUMBER() OVER (
              PARTITION BY test_cases.test_identity_id
              ORDER BY test_cases.created_at DESC, test_cases.id DESC
            ) AS row_number
          FROM test_cases
          WHERE test_cases.test_identity_id IN (?)
        ) latest_test_cases
        WHERE row_number = 1
      SQL
      ids
    ])
  end

  def self.latest_status_at_for(ids, statuses)
    TestCase
      .where(test_identity_id: ids, status: statuses)
      .group(:test_identity_id)
      .maximum(:created_at)
  end

  def self.bulk_update_summary_columns!(updates)
    return if updates.empty?

    columns = %i[
      last_status
      last_seen_at
      last_failed_at
      last_passed_at
      last_duration_ms
      file_path
      updated_at
    ]
    connection = self.connection

    updates.each_slice(200) do |slice|
      ids = slice.map { |id, _attrs| id.to_i }
      assignments = columns.map do |column|
        quoted_column = connection.quote_column_name(column)
        cases = slice.map do |id, attrs|
          "WHEN #{id.to_i} THEN #{connection.quote(attrs.fetch(column))}"
        end.join(" ")

        "#{quoted_column} = CASE #{connection.quote_column_name(:id)} #{cases} ELSE #{quoted_column} END"
      end

      connection.update(<<~SQL.squish)
        UPDATE #{quoted_table_name}
        SET #{assignments.join(", ")}
        WHERE #{connection.quote_column_name(:id)} IN (#{ids.join(", ")})
      SQL
    end
  end

  def self.interesting_for_repository(repository, query: nil, limit: INTERESTING_LIMIT)
    ensure_for_repository!(repository) if repository.test_identities.none? && TestCase.where(repository_id: repository.id).exists?

    scope = repository.test_identities
    if query.present?
      scope = scope.search_by_name(query)
      return scope.order(last_seen_at: :desc, id: :desc).limit(limit)
    end

    interesting_ids = []
    append_interesting_ids(interesting_ids, recent_failure_ids(repository, limit: limit))
    append_interesting_ids(interesting_ids, flaky_ids(repository, limit: limit))
    append_interesting_ids(interesting_ids, slow_ids(repository, limit: limit))
    interesting_ids = interesting_ids.first(limit)

    identities_by_id = scope.where(id: interesting_ids).index_by(&:id)
    interesting_ids.filter_map { |id| identities_by_id[id] }
  end

  def self.recent_failure_ids(repository, limit:)
    repository.test_identities
      .where.not(last_failed_at: nil)
      .where("last_failed_at >= ?", RECENT_FAILURE_WINDOW.ago)
      .order(last_failed_at: :desc, id: :desc)
      .limit(limit)
      .pluck(:id)
  end

  def self.flaky_ids(repository, limit:)
    repository.test_identities
      .where.not(last_failed_at: nil)
      .where.not(last_passed_at: nil)
      .where("last_failed_at >= ? OR last_passed_at >= ?", RECENT_FAILURE_WINDOW.ago, RECENT_FAILURE_WINDOW.ago)
      .order(last_failed_at: :desc, last_passed_at: :desc, id: :desc)
      .limit(limit)
      .pluck(:id)
  end

  def self.slow_ids(repository, limit:)
    repository.test_identities
      .where.not(last_duration_ms: nil)
      .where("last_duration_ms >= ?", 1_000)
      .order(last_duration_ms: :desc, last_seen_at: :desc, id: :desc)
      .limit(limit)
      .pluck(:id)
  end

  def self.append_interesting_ids(target, ids)
    ids.each do |id|
      target << id unless target.include?(id)
    end
  end

  def recent_stats(lookback: LIST_LOOKBACK)
    cases = test_cases.order(created_at: :desc).limit(lookback).pluck(:status, :duration_ms)
    total = cases.size
    failed = cases.count { |status, _duration| status == "failed" || status == "error" }
    passed = cases.count { |status, _duration| status == "passed" }
    durations = cases.filter_map { |_status, duration| duration }

    {
      total_count: total,
      failed_count: failed,
      passed_count: passed,
      failure_rate: total.positive? ? (failed.to_f / total) : 0.0,
      avg_duration_ms: durations.any? ? (durations.sum.to_f / durations.size).round : nil
    }
  end

  def interesting_reasons(stats: recent_stats)
    reasons = []
    reasons << "failing" if last_status.in?(%w[failed error]) || stats[:failed_count].positive?
    reasons << "flaky" if stats[:failed_count].positive? && stats[:passed_count].positive?
    reasons << "slow" if stats[:avg_duration_ms].to_i >= 1_000 || last_duration_ms.to_i >= 1_000
    reasons
  end

  def refresh_summary!
    latest = test_cases.order(created_at: :desc).first
    return unless latest

    update_columns(
      last_status: latest.status,
      last_seen_at: latest.created_at,
      last_failed_at: latest_failed_at,
      last_passed_at: latest_passed_at,
      last_duration_ms: latest.duration_ms,
      file_path: file_path.presence || latest.file_path,
      updated_at: Time.current
    )
  end

  def latest_failed_at
    test_cases.where(status: %w[failed error]).maximum(:created_at)
  end

  def latest_passed_at
    test_cases.where(status: "passed").maximum(:created_at)
  end
end
