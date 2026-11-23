module ConnectedAccounts
  class SystemInvocation
    CORE_SERVICE_IDENTITIES = [].freeze
    Capability = Data.define(:identity, :proof)
    private_constant :Capability

    class << self
      def call(account:, service_capability:, scopes:, purpose:, target: {})
        account = Account.find_by(id: account) unless account.is_a?(Account)
        deny! unless account&.owner_policy&.system_access?
        identity = verified_identity(service_capability)
        declaration = ProviderRegistry.fetch(account.provider)
        deny! unless declaration.system_service_identities.include?(identity)
        deny! if purpose.to_s.blank?

        context = McpToolContext.new(surface: :api, role: "system_service", user: account.credential_store_credential.created_by,
          permission_authorization: { system_service_identity: identity })
        AccountClient.with_access(account:, acting_mode: :as_service, scopes:, purpose:, context:, target:) { |access| yield access }
      end

      private

      def issue_capability(identity)
        identity = identity.to_s
        deny! unless CORE_SERVICE_IDENTITIES.include?(identity)

        Capability.new(identity:, proof: capability_proof)
      end

      def verified_identity(capability)
        deny! unless capability.is_a?(Capability) && capability.proof.equal?(capability_proof)

        capability.identity
      end

      def capability_proof = (@capability_proof ||= Object.new.freeze)

      def deny! = raise(AccountClient::Denied, "connected account not found")
    end
  end
end
