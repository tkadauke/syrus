module ConnectedAccounts
  class RefreshJob < ApplicationJob
    queue_as :low_priority_maintenance

    def perform(account_id)
      account = Account.find_by(id: account_id)
      return unless account&.connected?
      tokens = JSON.parse(account.credential_store_credential.payload)
      CredentialStore::Broker.refresh_credential!(credential: account.credential_store_credential,
        plugin_name: "connected_accounts", purpose: "scheduled OAuth refresh", user: account.owner_user,
        metadata: { connected_account_id: account.id }) { |payload| JSON.generate(TokenManager.refresh(account: account, tokens: JSON.parse(payload))) }
    rescue StandardError => error
      raise if error.is_a?(Problem) && error.retry_after

      TokenManager.mark_reauth!(account) if account&.persisted?
      nil
    end
  end
end
