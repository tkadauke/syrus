module ConnectedAccounts
  class OauthFlow
    InvalidState = Class.new(StandardError)
    FLOW_TTL = 10.minutes

    def self.start!(provider:, user:, redirect_uri:, scopes:, read_only: false)
      resolved = ResolvedProvider.fetch(provider)
      requested_scopes = Array(scopes).map(&:to_s).uniq
      unknown_scopes = requested_scopes - resolved.scope_keys
      raise ArgumentError, "requested scopes are not configured for this provider" if unknown_scopes.any?
      state = SecureRandom.urlsafe_base64(32)
      verifier = SecureRandom.urlsafe_base64(64)
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      flow = PendingFlow.create!(state_digest: PendingFlow.digest(state), provider: resolved.key,
        requested_scopes: requested_scopes, read_only: read_only, redirect_uri: redirect_uri,
        code_verifier: verifier, owner_user: user, expires_at: FLOW_TTL.from_now)
      result = resolved.call("authorization", Provider::AuthorizationContext.new(
        redirect_uri: flow.redirect_uri, state: state, requested_scopes: flow.requested_scopes,
        read_only: flow.read_only, code_challenge: challenge
      ))
      result.fetch(:authorize_url)
    end

    def self.complete!(state:, code:, provider: nil)
      flow = PendingFlow.live.find_by(state_digest: PendingFlow.digest(state))
      raise InvalidState, "OAuth state is invalid or expired" unless flow
      raise InvalidState, "OAuth state is invalid or expired" if provider.present? && flow.provider != provider.to_s
      flow.consume!
      resolved = ResolvedProvider.fetch(flow.provider)
      tokens = resolved.call("exchange_code", Provider::ExchangeCodeContext.new(
        code: code, redirect_uri: flow.redirect_uri, code_verifier: flow.code_verifier
      )).stringify_keys
      expires_at = normalize_expiry!(tokens)
      identity = resolved.call("identity", Provider::IdentityContext.new(access_token: tokens.fetch("access_token")))

      credential = CredentialMaterial.store_account!(user: flow.owner_user, provider: flow.provider,
        tokens: tokens, api_origins: resolved.api_origins)
      Account.create!(owner_user: flow.owner_user, provider: flow.provider,
        display_label: identity.fetch(:label).to_s, granted_scopes: flow.requested_scopes,
        status: "connected", read_only: flow.read_only, acting_modes: [ "as_owner" ],
        credential_store_credential: credential, token_expires_at: expires_at)
    end

    def self.normalize_expiry!(tokens)
      tokens["expires_at"] ||= (Time.current + Integer(tokens.delete("expires_in"))).iso8601
      Time.iso8601(tokens.fetch("expires_at"))
    rescue KeyError, ArgumentError
      raise Problem.new(code: "invalid_provider_response", message: "OAuth provider did not return a valid token expiry")
    end
  end
end
