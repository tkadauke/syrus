module ConnectedAccounts
  class Access
    REDACTED = "[connected account access redacted]".freeze

    def initialize(token)
      @token = token.to_s
      freeze
    end

    def authorization_header = "Bearer #{@token}"
    def to_s = REDACTED
    def inspect = "#<#{self.class.name} #{REDACTED}>"
    def to_json(*) = REDACTED.to_json
  end
end
