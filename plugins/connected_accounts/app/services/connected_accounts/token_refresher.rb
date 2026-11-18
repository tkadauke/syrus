module ConnectedAccounts
  class TokenRefresher
    class Unsupported < StandardError; end

    def self.call(account:, payload:)
      raise Unsupported, "#{account.provider_key} does not support token refresh"
    end
  end
end
