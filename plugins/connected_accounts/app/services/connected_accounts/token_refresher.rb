module ConnectedAccounts
  class TokenRefresher
    class Unsupported < StandardError; end

    def self.call(account:, payload:)
      providers = Syrus::PluginRegistry
        .providers_for("connected_accounts:provider")
        .select do |provider|
          provider.respond_to?(:key) && provider.key.to_s == account.provider_key && provider.respond_to?(:refresh)
        end
      unless providers.one?
        raise Unsupported, "#{account.provider_key} does not have one token refresh provider"
      end

      providers.first.refresh(account:, payload:)
    end
  end
end
