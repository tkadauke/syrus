module ConnectedAccounts
  class RefreshAccountsJob < ApplicationJob
    queue_as :low_priority_maintenance
    retry_on Provider::TransientError, wait: :polynomially_longer, attempts: 5

    def perform(account_id = nil)
      return unless ConnectedAccounts.enabled?

      scope = account_id ? Account.where(id: account_id) : Account.connected
      scope.find_each { |account| TokenMaintenance.call(account) }
    end
  end
end
