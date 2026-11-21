module ConnectedAccounts
  class RetentionExecutor
    Result = Data.define(:deleted_count, :backlog)

    def initialize(definition)
      @definition = definition
    end

    def call(batch_size: RetentionPruner::DEFAULT_BATCH_SIZE, max_batches: RetentionPruner::DEFAULT_MAX_BATCHES)
      window = @definition.retention_window
      return Result.new(deleted_count: 0, backlog: false) unless window

      cutoff = Time.current - window
      scope = Account.retention_candidates.where(updated_at: ...cutoff).limit(batch_size * max_batches)
      credential_ids = scope.pluck(:credential_store_credential_id)
      account_count = Account.where(id: scope.select(:id)).delete_all
      audit_count = CredentialStore::CredentialAccessEvent.where(credential_id: credential_ids).delete_all
      backlog = Account.retention_candidates.where(updated_at: ...cutoff).exists?
      Result.new(deleted_count: account_count + audit_count, backlog:)
    end
  end
end
