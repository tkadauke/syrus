require "digest"

class CanonicalizeTestInsightIdentities < ActiveRecord::Migration[8.1]
  RECENT_LIMIT = 20
  FINGERPRINT_SEPARATOR = "\0".freeze

  class MigrationIdentity < ActiveRecord::Base
    self.table_name = "test_insight_identities"
  end

  class MigrationCase < ActiveRecord::Base
    self.table_name = "test_insight_cases"
  end

  class MigrationRuntimeSummary < ActiveRecord::Base
    self.table_name = "test_insight_runtime_summaries"
  end

  def up
    return unless table_exists?(:test_insight_identities) && table_exists?(:test_insight_cases)

    MigrationIdentity.where.not(file_path: [ nil, "" ]).find_each do |identity|
      canonicalize_identity!(identity)
    end
  end

  def down
    # Canonical identities may combine histories that cannot be separated again.
  end

  private

  def canonicalize_identity!(identity)
    suite = canonical_suite(identity)
    name = identity.name.to_s.strip
    return if suite.blank? || name.blank?

    canonical_fingerprint = fingerprint(suite, name)
    existing = MigrationIdentity.find_by(repository_id: identity.repository_id, fingerprint: canonical_fingerprint)
    unless existing
      identity.update_columns(fingerprint: canonical_fingerprint, suite_name: suite, name: name, file_path: suite, updated_at: Time.current)
      return
    end
    return if existing.id == identity.id

    survivor = existing
    identity_ids = [ identity.id, survivor.id ].uniq

    MigrationIdentity.transaction do
      # Derived runtime percentiles cannot be combined safely. Removing them is
      # preferable to retaining partial summaries; normal ingestion rebuilds them.
      MigrationRuntimeSummary.where(test_identity_id: identity_ids).delete_all if table_exists?(:test_insight_runtime_summaries)
      MigrationCase.where(test_identity_id: identity_ids).update_all(test_identity_id: survivor.id)
      MigrationIdentity.where(id: identity_ids - [ survivor.id ]).delete_all

      survivor.update_columns(
        fingerprint: canonical_fingerprint,
        suite_name: suite,
        name: name,
        file_path: suite,
        **summary_attributes(survivor.id)
      )
    end
  end

  def canonical_suite(identity)
    identity.file_path.to_s.strip.sub(%r{\A\./}, "")
  end

  def fingerprint(suite, name)
    Digest::SHA256.hexdigest([ suite, name ].join(FINGERPRINT_SEPARATOR))
  end

  def summary_attributes(identity_id)
    scope = MigrationCase.where(test_identity_id: identity_id)
    latest = scope.order(created_at: :desc, id: :desc).first
    scored = scope.where(wip_repair_failure: false)
    recent = scored.order(created_at: :desc, id: :desc).limit(RECENT_LIMIT).to_a
    failed = recent.count { |test_case| test_case.status.in?(%w[failed error]) }
    passed = recent.count { |test_case| test_case.status == "passed" }
    durations = recent.filter_map(&:duration_ms)

    {
      last_status: latest&.status,
      last_seen_at: latest&.created_at,
      last_failed_at: scored.where(status: %w[failed error]).maximum(:created_at),
      last_passed_at: scored.where(status: "passed").maximum(:created_at),
      last_duration_ms: latest&.duration_ms,
      recent_sample_count: recent.size,
      recent_failed_count: failed,
      recent_passed_count: passed,
      recent_avg_duration_ms: durations.any? ? (durations.sum.to_f / durations.size).round : nil,
      updated_at: Time.current
    }
  end
end
