module ConnectedAccounts
  class TokenMaintenance
    REFRESH_WINDOW = 5.minutes

    def self.call(account)
      credential = account.credential_store_credential
      tokens = JSON.parse(credential.payload)
      declaration = ProviderRegistry.fetch(account.provider)
      if tokens["expires_at"].present? && Time.iso8601(tokens.fetch("expires_at")) <= REFRESH_WINDOW.from_now
        CredentialStore::Broker.refresh_credential!(credential: credential, plugin_name: "connected_accounts", purpose: "[purpose redacted]",
          user: account.owner_user, metadata: { connected_account_id: account.id, provider: account.provider }) do |payload|
          current = JSON.parse(payload)
          refreshed = declaration.call("refresh", Provider::RefreshContext.new(tokens: current)).stringify_keys
          refreshed["refresh_token"] ||= current["refresh_token"]
          refreshed["expires_at"] = refreshed.delete("expires_at") || refreshed.delete("expires_in").to_i.seconds.from_now.iso8601
          JSON.generate(refreshed)
        end
      end
      fresh = JSON.parse(credential.reload.payload)
      result = declaration.call("validate", Provider::ValidateContext.new(access_token: fresh.fetch("access_token")))
      account.update!(status: "needs_reauth") unless result[:healthy] || result["healthy"]
    rescue Provider::PermanentError, KeyError, JSON::ParserError, ArgumentError
      account.update!(status: "needs_reauth")
    end
  end
end
