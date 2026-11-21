module ConnectedAccounts
  class PurgeContributor
    include Syrus::Plugin::PurgeContributor
    def self.purge_report(plugin_name)
      return [] unless plugin_name == "connected_accounts"

      count = CredentialStore::CredentialAccessEvent.where(credential_id: Account.select(:credential_store_credential_id)).count
      count.positive? ? [ "#{count} connected-account credential audit rows" ] : []
    end

    def self.purge!(plugin_name)
      return [] unless plugin_name == "connected_accounts"

      deleted = CredentialStore::CredentialAccessEvent.where(credential_id: Account.select(:credential_store_credential_id)).delete_all
      deleted.positive? ? [ "#{deleted} connected-account credential audit rows" ] : []
    end
  end
end
