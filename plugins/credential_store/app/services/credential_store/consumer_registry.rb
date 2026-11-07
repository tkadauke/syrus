module CredentialStore
  class ConsumerRegistry
    Consumer = Data.define(:name, :kind, :credential_types, :description) do
      def compatible_with?(credential_type)
        credential_types.include?("*") || credential_types.include?(credential_type.to_s)
      end
    end

    CONSUMERS = [
      Consumer.new(
        name: "credential_store_ssh_exec",
        kind: :typed,
        credential_types: %w[ssh_private_key],
        description: "Execute a permission-authorized SSH command without exposing the private key."
      ),
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
      def find(name) = CONSUMERS[name.to_s]

      def typed_for(credential_type)
        compatible_for(credential_type, kind: :typed)
      end

      def raw_wrappers_for(credential_type)
        compatible_for(credential_type, kind: :raw_wrapper)
      end

      private

      def compatible_for(credential_type, kind:)
        CONSUMERS.values.select { |consumer| consumer.kind == kind && consumer.compatible_with?(credential_type) }
      end
    end
  end
end
