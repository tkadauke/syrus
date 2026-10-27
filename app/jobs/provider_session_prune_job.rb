class ProviderSessionPruneJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  PAYLOAD_BATCH_SIZE = 1_000
  MAX_PAYLOAD_BATCHES = 50

  # Daily housekeeping. Clear heavy payloads after one week, then delete rows
  # for terminal Runs beyond the configurable row-retention window. Active
  # Runs are never touched.
  #
  # We intentionally keep payloads for recent succeeded workflow Runs:
  # downstream short agentic steps may need to rehydrate provider resume state
  # after worker movement or deploys.
  def perform
    n_payloads_pruned = prune_payloads
    n_deleted = RetentionPruner.call(
      scope: ProviderSession.prunable,
      retention_key: :provider_session,
      cutoff: ProviderSession.retention_cutoff
    )
    Rails.logger.info("[ProviderSessionPrune] cleared #{n_payloads_pruned} session payloads") if n_payloads_pruned > 0
    Rails.logger.info("[ProviderSessionPrune] deleted #{n_deleted} sessions") if n_deleted > 0
  end

  private

  def prune_payloads
    return 0 if AppSetting.current.provider_session_archive_before_delete?

    pruned = 0

    MAX_PAYLOAD_BATCHES.times do
      ids = ProviderSession.payload_prunable.reorder(id: :asc).limit(PAYLOAD_BATCH_SIZE).pluck(:id)
      break if ids.empty?

      pruned += ProviderSession.where(id: ids).update_all( # rubocop:disable Rails/SkipsModelValidations
        transcript_jsonl: nil,
        normalized_messages: nil,
        transcript_pruned: true
      )
    end

    pruned
  end
end
