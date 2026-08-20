require "digest"

class TestIdentity < ApplicationRecord
  FINGERPRINT_SEPARATOR = "\0".freeze
  RECENT_FAILURE_WINDOW = 14.days
  HISTORY_LIMIT = 100
  LIST_LOOKBACK = 20

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

  def self.ensure_for_repository!(repository)
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
    TestIdentitySearchIndex.upsert_many(where(id: identities.values.map(&:id)).includes(:repository))
  end

  def self.refresh_many!(ids)
    ids = Array(ids).compact.uniq
    return if ids.empty?

    where(id: ids).find_each(&:refresh_summary!)
  end

  def self.interesting_for_repository(repository, query: nil, limit: 50)
    ensure_for_repository!(repository) if repository.test_identities.none? && TestCase.where(repository_id: repository.id).exists?

    scope = repository.test_identities
    if query.present?
      scope = scope.search_by_name(query)
      return scope.order(last_seen_at: :desc, id: :desc).limit(limit)
    end

    recent_failed_ids = TestCase
      .where(repository_id: repository.id, status: %w[failed error])
      .where("created_at >= ?", RECENT_FAILURE_WINDOW.ago)
      .where.not(test_identity_id: nil)
      .group(:test_identity_id)
      .order(Arel.sql("MAX(created_at) DESC"))
      .limit(limit)
      .pluck(:test_identity_id)

    identities_by_id = scope.where(id: recent_failed_ids).index_by(&:id)
    recent_failed_ids.filter_map { |id| identities_by_id[id] }
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
