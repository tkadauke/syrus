module ConnectedAccounts
  class SystemInvocation
    CORE_SERVICES = {}.freeze

    class << self
      def call(account:, service_identity:, scopes:, purpose:, target: {}, input: {})
        account = Account.find_by(id: account) unless account.is_a?(Account)
        deny! unless account&.owner_policy&.system_access?
        identity = service_identity.to_s
        declaration = ProviderRegistry.fetch(account.provider)
        service = CORE_SERVICES[identity] || declaration.system_service_for(identity)
        deny! unless service&.respond_to?(:system_invoke)
        deny! if purpose.to_s.blank?

        context = McpToolContext.new(surface: :api, role: "system_service", user: account.credential_store_credential.created_by,
          permission_authorization: { system_service_identity: identity })
        AccountClient.with_access(account:, acting_mode: :as_service, scopes:, purpose:, context:, target:) do |access|
          invocation = Provider::SystemInvocationContext.new(access:, identity:, purpose: purpose.to_s,
            target: target.to_h.freeze, input: input.to_h.freeze)
          Invoker.call(provider: service, capability: "system_invoke", context: invocation)
        end
      end

      private

      def deny! = raise(AccountClient::Denied, "connected account not found")
    end
  end
end
