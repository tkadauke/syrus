module CredentialStore
  class ConsumerRegistry
    Consumer = Data.define(:name, :kind, :credential_types, :description) do
      def compatible_with?(credential_type)
        credential_types.include?("*") || credential_types.include?(credential_type.to_s)
      end
    end

    BUILT_IN_CONSUMERS = [
      Consumer.new(
        name: "credential.exec",
        kind: :raw_wrapper,
        credential_types: %w[*],
        description: "Materialize the secret for an arbitrary child process."
      ),
      Consumer.new(
        name: "credential.ssh-agent",
        kind: :raw_wrapper,
        credential_types: %w[ssh_private_key],
        description: "Materialize an SSH key in a temporary agent for an arbitrary child process."
      )
    ].index_by(&:name).freeze

    class << self
      def find(name) = consumers[name.to_s]

      def consumers
        plugin_consumers = Syrus::Host::PluginRegistry.credential_types.filter_map do |declaration|
          consumer = declaration["typed_consumer"]
          next unless consumer

          Consumer.new(
            name: consumer.fetch("name"),
            kind: :typed,
            credential_types: [ declaration.fetch("name") ].freeze,
            description: consumer.fetch("description")
          )
        end.index_by(&:name)
        duplicates = BUILT_IN_CONSUMERS.keys & plugin_consumers.keys
        raise ArgumentError, "duplicate credential consumer(s): #{duplicates.join(', ')}" if duplicates.any?

        BUILT_IN_CONSUMERS.merge(plugin_consumers).freeze
      end

      def plugin_managed_type?(credential_type)
        owner = Syrus::Host::PluginRegistry.credential_type_owner(credential_type)
        owner.present? && owner != "credential_store"
      end

      def typed_for(credential_type)
        compatible_for(credential_type, kind: :typed)
      end

      def raw_wrappers_for(credential_type)
        compatible_for(credential_type, kind: :raw_wrapper)
      end

      private

      def compatible_for(credential_type, kind:)
        consumers.values.select { |consumer| consumer.kind == kind && consumer.compatible_with?(credential_type) }
      end
    end
  end
end
