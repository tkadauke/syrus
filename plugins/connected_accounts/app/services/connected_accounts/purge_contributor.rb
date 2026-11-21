module ConnectedAccounts
  class PurgeContributor
    include Syrus::Plugin::PurgeContributor
    def self.purge_report(plugin_name)
      return [] unless plugin_name == "connected_accounts"

      credential_ids = Account.select(:credential_store_credential_id)
      audit_count = CredentialStore::CredentialAccessEvent.where(credential_id: credential_ids).count
      credential_count = managed_credentials(credential_ids).count
      report(audit_count:, credential_count:)
    end

    def self.purge!(plugin_name)
      return [] unless plugin_name == "connected_accounts"

      credential_ids = Account.pluck(:credential_store_credential_id)
      audit_count = credential_count = 0
      Account.transaction do
        audit_count = CredentialStore::CredentialAccessEvent.where(credential_id: credential_ids).delete_all
        credential_count = managed_credentials(credential_ids).delete_all
      end
      report(audit_count:, credential_count:)
    end

    def self.managed_credentials(ids)
      CredentialStore::Credential.where(id: ids, credential_type: AccountClient::CREDENTIAL_TYPE)
    end
    private_class_method :managed_credentials

    def self.report(audit_count:, credential_count:)
      []
        .tap { |items| items << "#{audit_count} connected-account credential audit rows" if audit_count.positive? }
        .tap { |items| items << "#{credential_count} connected-account encrypted credentials" if credential_count.positive? }
    end
    private_class_method :report
  end
end
