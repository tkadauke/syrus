module RetentionPolicyExecutors
  class ProviderSession < Default
    PAYLOAD_BATCH_SIZE = 1_000
    MAX_PAYLOAD_BATCHES = 50

    def call(...)
      payload_count, payload_backlog = prune_payloads unless @definition.setting.archive_before_delete?
      result = super
      Result.new(
        deleted_count: result.deleted_count + payload_count.to_i,
        backlog: result.backlog || payload_backlog == true
      )
    end

    private

    def prune_payloads
      pruned = 0
      MAX_PAYLOAD_BATCHES.times do
        ids = ::ProviderSession.payload_prunable.reorder(id: :asc).limit(PAYLOAD_BATCH_SIZE).pluck(:id)
        break if ids.empty?

        pruned += ::ProviderSession.where(id: ids).update_all( # rubocop:disable Rails/SkipsModelValidations
          transcript_jsonl: nil,
          normalized_messages: nil,
          transcript_pruned: true
        )
      end
      [ pruned, ::ProviderSession.payload_prunable.exists? ]
    end
  end
end
