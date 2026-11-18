module ConnectedAccounts
  module CredentialMaterial
    module_function

    def store_account!(user:, provider:, tokens:, api_origins:)
      CredentialStore::Credential.create!(name: "connected-account-#{provider}-#{SecureRandom.hex(6)}",
        description: "Connected account for #{provider}", credential_type: AccountClient::CREDENTIAL_TYPE,
        scope_type: "user", scope_id: user.id, created_by: user, owner_user: user,
        payload: JSON.generate(tokens), safe_metadata: { "refreshable" => tokens["refresh_token"].present? },
        target_constraints: { "allowed_url_prefixes" => api_origins }, allowed_surfaces: %w[api chat workflow],
        allowed_tools: [ AccountClient::BROKER_TOOL_NAME ])
    end

    def store_client!(user:, key:, client_id:, client_secret:)
      CredentialStore::Credential.create!(name: "connected-account-client-#{key}",
        description: "OAuth client registration for #{key}", credential_type: "connected_accounts.oauth_client",
        scope_type: "instance", created_by: user, payload: JSON.generate(client_id: client_id, client_secret: client_secret),
        safe_metadata: {}, target_constraints: {}, allowed_surfaces: [ "api" ], allowed_tools: [ "connected_accounts.oauth_admin" ])
    end

    def erase!(credential, user:, action: "revoke")
      credential.with_lock do
        credential.update!(payload: JSON.generate(revoked: true), revoked_at: Time.current)
        CredentialStore::CredentialAccessEvent.record!(credential: credential, user: user, surface: "api",
          tool_name: "connected_accounts", action: action, result: "allowed", metadata: { token_material_deleted: true })
      end
    end
  end
end
