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
      # Pluck the batch once and delete by literal ids. MySQL rejects a LIMIT
      # inside an IN subquery ("doesn't yet support 'LIMIT & IN/ALL/ANY/SOME
      # subquery'"), so `where(id: scope.select(:id))` failed every pass in
      # production while SQLite accepted it in specs.
      rows = Account.retention_candidates.where(updated_at: ...cutoff)
        .limit(batch_size * max_batches)
        .pluck(:id, :credential_store_credential_id)
      account_ids = rows.map(&:first)
      credential_ids = rows.map(&:last).compact
      account_count = audit_count = credential_count = 0
      Account.transaction do
        audit_count = CredentialStore::CredentialAccessEvent.where(credential_id: credential_ids).delete_all
        account_count = Account.where(id: account_ids).delete_all
        credential_count = CredentialStore::Credential.where(
          id: credential_ids, credential_type: AccountClient::CREDENTIAL_TYPE
        ).delete_all
      end
      backlog = Account.retention_candidates.where(updated_at: ...cutoff).exists?
      Result.new(deleted_count: account_count + audit_count + credential_count, backlog:)
    end
  end
end
