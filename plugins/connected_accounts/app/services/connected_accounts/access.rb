module ConnectedAccounts
  class Access
    REDACTED = "[connected account access redacted]".freeze

    def initialize(token)
      @token = token.to_s
      freeze
    end

    def authorization_header = "Bearer #{@token}"

    # Block-scoped raw token for a provider's own registered `system_invoke`
    # implementation, for services whose wire format is not a Bearer header
    # (Discord's `Bot <token>`, Telegram's token-in-path). The token is never
    # handed out beyond the block; the block's own value is returned, so
    # callers must return only already-redacted results from it.
    def with_token
      yield @token
    end

    def to_s = REDACTED
    def inspect = "#<#{self.class.name} #{REDACTED}>"
    def to_json(*) = REDACTED.to_json
  end
end
