module ConnectedAccounts
  module DataCleanup
    def self.install_into(scope)
      scope.effect("connected account user data") do
        Syrus::DataCleanup.register("User", "connected_accounts.user_data") do |user|
          Account.where(owner_user_id: user.id).find_each do |account|
            CredentialMaterial.erase!(account.credential_store_credential, user: user) unless account.credential_store_credential.revoked?
            account.destroy!
          end
          PendingFlow.where(owner_user_id: user.id).delete_all
          ProviderConfig.where(created_by_id: user.id).update_all(created_by_id: User.where.not(id: user.id).order(:id).pick(:id)) if User.where.not(id: user.id).exists?
        end
      end
    end
  end
end
