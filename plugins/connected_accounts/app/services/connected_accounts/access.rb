module ConnectedAccounts
  class Access
    REDACTED = "#<ConnectedAccounts::Access token=[REDACTED]>".freeze

    def initialize(token:, expires_at:, scopes:, api_origins:)
      @token = token
      @expires_at = expires_at
      @scopes = scopes.freeze
      @api_origins = api_origins.freeze
      @revoked = false
    end

    attr_reader :expires_at, :scopes, :api_origins

    def authorization_header
      raise CredentialStore::Broker::Denied, "materialization lease revoked" if revoked?

      "Bearer #{@token}"
    end

    def revoked? = @revoked

    def revoke!
      @revoked = true
      @token = nil
      self
    end

    def to_s = REDACTED
    def inspect = REDACTED
    def to_json(*) = REDACTED.to_json
  end
end
