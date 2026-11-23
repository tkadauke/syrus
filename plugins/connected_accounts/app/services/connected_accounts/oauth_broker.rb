module ConnectedAccounts
  class OauthBroker
    class Error < StandardError; end

    def self.complete!(provider:, state:, code:, user:, session_binding:, redirect_uri:)
      declaration = ProviderRegistry.fetch(provider)
      oauth_state = OauthState.consume!(token: state, user: user, session_binding: session_binding, provider: provider)
      tokens = declaration.call("exchange_code", Provider::ExchangeCodeContext.new(code:, redirect_uri:, code_verifier: oauth_state.code_verifier)).stringify_keys
      raise Error, "provider returned no access token" if tokens["access_token"].blank?
      tokens["expires_at"] = tokens.delete("expires_at") || tokens.delete("expires_in").to_i.seconds.from_now.iso8601
      identity = declaration.call("identity", Provider::IdentityContext.new(access_token: tokens["access_token"])).stringify_keys
      granted = Array(tokens.delete("scope").to_s.split.presence || oauth_state.requested_scopes)
      granted &= oauth_state.requested_scopes
      config = ProviderConfig.find_by(provider_key: provider)

      Account.transaction do
        account = Account.find_or_initialize_by(owner_kind: "user", owner_user: user, provider: provider, display_label: identity.fetch("label"))
        credential = account.credential_store_credential || CredentialStore::Credential.new
        credential.assign_attributes(name: "connected-account-#{provider}-#{user.id}-#{OauthState.digest(identity.fetch('label'))[0, 12]}",
          credential_type: AccountClient::CREDENTIAL_TYPE, scope_type: "user", scope_id: user.id, owner_user: user,
          created_by: user, payload: JSON.generate(tokens), safe_metadata: { "refreshable" => tokens["refresh_token"].present? },
          target_constraints: { "allowed_url_prefixes" => Array(config&.api_origins) }, allowed_tools: [ AccountClient::BROKER_TOOL_NAME ],
          last_rotated_at: Time.current)
        credential.save!
        account.update!(credential_store_credential: credential, granted_scopes: granted, scope_ceiling: granted,
          status: "connected", read_only: oauth_state.read_only, acting_modes: [ "as_self" ])
        account
      end
    end

    def self.needs_reauth!(account)
      account.update!(status: "needs_reauth") unless account.needs_reauth?
      account
    end
  end
end
