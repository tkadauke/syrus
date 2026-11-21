module ConnectedAccounts
  class RefreshAccountsJob < Syrus::Host::BackgroundJob
    queue_as :low_priority_maintenance
    retry_on Provider::TransientError, wait: :polynomially_longer, attempts: 5

    def perform(account_id = nil)
      return unless ConnectedAccounts.enabled?

      if account_id
        account = Account.connected.find_by(id: account_id)
        TokenMaintenance.call(account) if account
      else
        Account.connected.find_each { |account| self.class.perform_later(account.id) }
      end
    end
  end
end
