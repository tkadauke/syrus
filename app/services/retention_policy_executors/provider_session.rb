module RetentionPolicyExecutors
  class ProviderSession < Default
    PAYLOAD_BATCH_SIZE = 1_000
    MAX_PAYLOAD_BATCHES = 50

    def call(...)
      prune_payloads unless @definition.setting.archive_before_delete?
      super
    end

    private

    def prune_payloads
      MAX_PAYLOAD_BATCHES.times do
        ids = ::ProviderSession.payload_prunable.reorder(id: :asc).limit(PAYLOAD_BATCH_SIZE).pluck(:id)
        break if ids.empty?

        ::ProviderSession.where(id: ids).update_all( # rubocop:disable Rails/SkipsModelValidations
          transcript_jsonl: nil,
          normalized_messages: nil,
          transcript_pruned: true
        )
      end
    end
  end
end
