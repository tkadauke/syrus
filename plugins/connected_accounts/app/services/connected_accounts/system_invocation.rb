module ConnectedAccounts
  class SystemInvocation
    CORE_SERVICES = {}.freeze
    Binding = Data.define(:identity, :proof)
    Registration = Data.define(:identity, :service, :provider_key)
    private_constant :Binding, :Registration

    class << self
      def call(account:, service_binding:, scopes:, purpose:, target: {}, input: {})
        account = Account.find_by(id: account) unless account.is_a?(Account)
        deny! unless account&.owner_policy&.system_access?
        registration = registration_for(service_binding)
        deny! unless registration
        declaration = ProviderRegistry.fetch(account.provider)
        deny! unless authorized_registration?(registration, declaration)
        deny! if purpose.to_s.blank?

        context = Syrus::Host::ToolContext.new(surface: :api, role: "system_service", user: account.credential_store_credential.created_by,
          permission_authorization: { system_service_identity: registration.identity })
        AccountClient.with_access(account:, acting_mode: :as_service, scopes:, purpose:, context:, target:) do |access|
          invocation = Provider::SystemInvocationContext.new(access:, identity: registration.identity, purpose: purpose.to_s,
            target: target.to_h.freeze, input: input.to_h.freeze)
          Invoker.call(provider: registration.service, capability: "system_invoke", context: invocation)
        end
      end

      private

      def register_provider!(declaration)
        service = declaration.provider.constantize
        declaration.system_service_identities.each do |identity|
          inject_binding(service, Registration.new(identity:, service:, provider_key: declaration.key))
        end
        nil
      end

      def register_core_services!
        CORE_SERVICES.each do |identity, service|
          inject_binding(service, Registration.new(identity: identity.to_s, service:, provider_key: nil))
        end
        nil
      end

      def inject_binding(service, registration)
        binding = Binding.new(identity: registration.identity, proof: binding_proof).freeze
        registrations_mutex.synchronize { registrations[binding] = registration }
        service.register_system_access(registration.identity, binding)
      end

      def registration_for(binding)
        return unless binding.is_a?(Binding) && binding.proof.equal?(binding_proof)

        registrations_mutex.synchronize { registrations[binding] }
      end

      def authorized_registration?(registration, declaration)
        if registration.provider_key.present?
          return declaration.system_service_identities.include?(registration.identity) &&
            registration.provider_key == declaration.key &&
            registration.service.equal?(declaration.provider.constantize)
        end

        CORE_SERVICES[registration.identity].equal?(registration.service)
      end

      # Keys weak, values strong: an ObjectSpace::WeakMap also holds its values
      # weakly, so a Registration nothing else references would be collected
      # and a valid binding would suddenly stop resolving.
      def registrations = (@registrations ||= ObjectSpace::WeakKeyMap.new)
      def registrations_mutex = (@registrations_mutex ||= Mutex.new)
      def binding_proof = (@binding_proof ||= Object.new.freeze)

      def deny! = raise(AccountClient::Denied, "connected account not found")
    end

    send(:register_core_services!)
  end
end
