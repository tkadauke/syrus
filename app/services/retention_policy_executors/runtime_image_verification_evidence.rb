module RetentionPolicyExecutors
  class RuntimeImageVerificationEvidence < Default
    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      window = @definition.retention_window
      return Result.new(deleted_count: 0, backlog: false) unless window

      scope = @definition.model_class.public_send(@definition.scope_name).where(issued_at: ...Time.current - window)
      records = scope.includes(attempt: %i[scan_evidence policy_evidence]).order(:id).limit(batch_size * max_batches).to_a
      records.each { |attestation| purge_exact_evidence(attestation) }
      Result.new(deleted_count: records.size, backlog: scope.exists?)
    end

    private

    def purge_exact_evidence(attestation)
      attestation.attempt.scan_evidence&.sbom&.purge
      attestation.attempt.scan_evidence&.scan_report&.purge
      attestation.attempt.policy_evidence&.report&.purge
      attestation.update!(exact_evidence_purged_at: Time.current)
    end
  end
end
