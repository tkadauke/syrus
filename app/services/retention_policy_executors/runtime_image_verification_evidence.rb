module RetentionPolicyExecutors
  class RuntimeImageVerificationEvidence < Default
    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      window = @definition.retention_window
      return Result.new(deleted_count: 0, backlog: false) unless window
      scope = RuntimeImageVerificationAttestation.exact_evidence_retention_candidates.where(issued_at: ..(Time.current - window))
      purged = 0
      max_batches.times do
        rows = scope.includes(attempt: %i[scan_evidence policy_evidence]).limit(batch_size).to_a
        break if rows.empty?
        rows.each do |attestation|
          attestation.attempt.scan_evidence&.sbom&.purge
          attestation.attempt.scan_evidence&.scan_report&.purge
          attestation.attempt.policy_evidence&.report&.purge
          attestation.update!(exact_evidence_purged_at: Time.current)
          purged += 1
        end
      end
      Result.new(deleted_count: purged, backlog: scope.exists?)
    end
  end
end
