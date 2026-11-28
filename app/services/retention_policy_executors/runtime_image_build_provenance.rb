module RetentionPolicyExecutors
  class RuntimeImageBuildProvenance < Default
    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      cutoff = retention_cutoff
      return Result.new(deleted_count: 0, backlog: false) unless cutoff

      pruned = prune_verification_attempts(cutoff, batch_size, max_batches)
      pruned += clear_build_logs(cutoff, batch_size, max_batches)
      pruned += purge_source_archives(cutoff, batch_size, max_batches)
      Result.new(deleted_count: pruned, backlog: backlog?(cutoff))
    end

    private

    def prune_verification_attempts(cutoff, batch_size, max_batches)
      RetentionPruner.call(
        scope: prunable_verification_attempts(cutoff),
        cutoff: cutoff,
        batch_size: batch_size,
        max_batches: max_batches,
        destroy: true
      )
    end

    def prunable_verification_attempts(cutoff)
      scope = RuntimeImageVerificationAttempt.prunable.where(finished_at: ..cutoff)
      %i[prior_attestation_id triggering_attestation_id].reduce(scope) do |candidates, reference|
        protected_attempt_ids = RuntimeImageVerificationAttestation
          .where(id: RuntimeImageRevocationCandidate.select(reference))
          .select(:runtime_image_verification_attempt_id)
        candidates.where.not(id: protected_attempt_ids)
      end
    end

    def clear_build_logs(cutoff, batch_size, max_batches)
      prune_payloads(
        RuntimeImageBuildEvidence.retention_payload_candidates.where(finished_at: ..cutoff),
        batch_size,
        max_batches
      ) { |ids| RuntimeImageBuildEvidence.where(id: ids).update_all(log: nil) } # rubocop:disable Rails/SkipsModelValidations
    end

    def purge_source_archives(cutoff, batch_size, max_batches)
      scope = RuntimeImageBuildRequest.source_archive_retention_candidates.where(finished_at: ..cutoff)
      purged = 0
      max_batches.times do
        rows = scope.includes(source_archive_attachment: :blob).limit(batch_size).to_a
        break if rows.empty?
        rows.each do |request|
          request.source_archive.purge
          purged += 1
        end
      end
      purged
    end

    def prune_payloads(scope, batch_size, max_batches)
      pruned = 0
      max_batches.times do
        ids = scope.limit(batch_size).pluck(:id)
        break if ids.empty?
        pruned += yield(ids)
      end
      pruned
    end

    def backlog?(cutoff)
      prunable_verification_attempts(cutoff).exists? ||
        RuntimeImageBuildEvidence.retention_payload_candidates.where(finished_at: ..cutoff).exists? ||
        RuntimeImageBuildRequest.source_archive_retention_candidates.where(finished_at: ..cutoff).exists?
    end
  end
end
