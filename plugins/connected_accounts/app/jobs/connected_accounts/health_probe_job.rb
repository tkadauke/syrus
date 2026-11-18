module ConnectedAccounts
  class HealthProbeJob < ApplicationJob
    queue_as :low_priority_maintenance

    def perform(account_id = nil)
      accounts = account_id ? Account.where(id: account_id) : Account.due_for_health_check
      accounts.find_each { |account| probe(account) }
    end

    private

    def probe(account)
      tokens = JSON.parse(account.credential_store_credential.payload)
      result = ResolvedProvider.fetch(account.provider).call("validate",
        Provider::ValidateContext.new(access_token: tokens.fetch("access_token")))
      account.update!(status: result.fetch(:healthy) ? "connected" : "needs_reauth",
        health_message: result[:message].to_s.truncate(255), last_health_checked_at: Time.current)
    rescue Problem => error
      raise if error.retry_after
      account.update!(status: "error", health_message: error.message, last_health_checked_at: Time.current)
    end
  end
end
