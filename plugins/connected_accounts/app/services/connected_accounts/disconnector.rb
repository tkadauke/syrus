module ConnectedAccounts
  module Disconnector
    module_function

    def call(account:, user:)
      return account if account.revoked?
      account.with_lock do
        tokens = JSON.parse(account.credential_store_credential.payload)
        ResolvedProvider.fetch(account.provider).call("revoke", Provider::RevokeContext.new(tokens: tokens))
      ensure
        Account.transaction do
          CredentialMaterial.erase!(account.credential_store_credential, user: user)
          account.update!(status: "revoked", token_expires_at: nil)
        end
      end
      account
    end
  end
end
