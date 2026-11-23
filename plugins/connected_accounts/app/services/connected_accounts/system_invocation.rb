module ConnectedAccounts
  class SystemInvocation
    CORE_SERVICE_IDENTITIES = [].freeze

    class << self
      def call(account:, service_identity:, scopes:, purpose:, target: {})
        account = Account.find_by(id: account) unless account.is_a?(Account)
        deny! unless account&.owner_policy&.system_access?
        identity = service_identity.to_s
        declaration = ProviderRegistry.fetch(account.provider)
        deny! unless (CORE_SERVICE_IDENTITIES + declaration.system_service_identities).include?(identity)
        deny! if purpose.to_s.blank?

        context = McpToolContext.new(surface: :api, role: "system_service", user: account.credential_store_credential.created_by,
          permission_authorization: { system_service_identity: identity })
        AccountClient.with_access(account:, acting_mode: :as_service, scopes:, purpose:, context:, target:) { |access| yield access }
      end

      private

      def deny! = raise(AccountClient::Denied, "connected account not found")
    end
  end
end
