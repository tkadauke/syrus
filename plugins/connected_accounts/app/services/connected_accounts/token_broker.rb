module ConnectedAccounts
  class TokenBroker
    class Error < StandardError; end

    def self.connect!(provider:, token:, label:, admin:)
      raise Error, "administrator required" unless admin&.admin?
      declaration = ProviderRegistry.fetch(provider)
      raise Error, "provider does not support token entry" unless declaration.token_authorization?
      secret = token.to_s
      raise Error, "token is required" if secret.blank?

      validation = declaration.call("validate", Provider::ValidateContext.new(access_token: secret)).to_h.stringify_keys
      raise Error, validation["message"].presence || "provider rejected the token" unless validation["healthy"]
      origins = declaration.api_origins.presence || Array(ProviderConfig.find_by(provider_key: provider)&.api_origins)
      raise Error, "provider API origins are not configured" if origins.empty?
      label = label.to_s.strip.presence || identity_label(declaration, secret)

      Account.transaction do
        account = Account.find_or_initialize_by(owner_kind: "instance", owner_user_id: nil, provider: provider)
        previous = account.credential_store_credential
        revoke_failure = revoke_previous(declaration, previous)
        credential = CredentialStore::Credential.create!(name: "connected-account-#{provider}-instance-#{SecureRandom.hex(6)}",
          credential_type: AccountClient::CREDENTIAL_TYPE, scope_type: "instance", scope_id: nil, owner_user: nil,
          created_by: admin, payload: JSON.generate(access_token: secret), safe_metadata: { "refreshable" => false },
          target_constraints: { "allowed_url_prefixes" => origins }, allowed_surfaces: [ "api" ],
          allowed_tools: [ AccountClient::BROKER_TOOL_NAME ],
          last_rotated_at: Time.current)
        account.update!(display_label: label.to_s.strip.presence || declaration.display_name,
          credential_store_credential: credential, granted_scopes: declaration.connect_scope_keys,
          scope_ceiling: declaration.connect_scope_keys, status: "connected", read_only: false, acting_modes: [ "as_service" ])
        previous&.update!(revoked_at: Time.current)
        CredentialStore::CredentialAccessEvent.record!(credential:, user: admin, surface: "admin",
          tool_name: AccountClient::BROKER_TOOL_NAME, action: previous ? "rotate" : "create", result: "allowed",
          metadata: { provider:, connected_account_id: account.id, provider_revoke_failure: revoke_failure }.compact)
        account
      end
    rescue StandardError => error
      raise Error, CredentialStore::Broker.redact(error.message, extra_secrets: [ token.to_s ])
    end

    # The single instance-owned account for a token provider, if any.
    def self.instance_account(provider)
      Account.find_by(owner_kind: "instance", owner_user_id: nil, provider: provider.to_s)
    end

    def self.identity_label(declaration, secret)
      return unless declaration.capabilities.include?("identity")

      label = declaration.call("identity", Provider::IdentityContext.new(access_token: secret)).to_h.stringify_keys["label"]
      CredentialStore::Broker.redact(label.to_s, extra_secrets: [ secret ]).presence
    rescue StandardError
      nil
    end
    private_class_method :identity_label

    def self.revoke_previous(declaration, credential)
      return unless credential

      declaration.call("revoke", Provider::RevokeContext.new(tokens: JSON.parse(credential.payload)))
      nil
    rescue StandardError => error
      error.class.name
    end
    private_class_method :revoke_previous
  end
end
