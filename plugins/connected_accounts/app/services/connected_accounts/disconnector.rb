module ConnectedAccounts
  class Disconnector
    def self.call(account:, user:)
      credential = account.credential_store_credential
      tokens = JSON.parse(credential.payload)
      failure = nil
      begin
        ProviderRegistry.fetch(account.provider).call("revoke", Provider::RevokeContext.new(tokens: tokens))
      rescue StandardError => error
        failure = error.class.name
      ensure
        credential.update!(revoked_at: Time.current)
        account.update!(status: "revoked")
        CredentialStore::CredentialAccessEvent.record!(credential: credential, user: user, surface: "api",
          tool_name: "connected_accounts.broker", action: "revoke", result: failure ? "failed" : "allowed",
          metadata: { provider: account.provider, provider_failure: failure })
      end
      account
    end
  end
end
