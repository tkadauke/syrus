module Syrus
  module Plugin
    # Provisional v1 service contract implemented by replication plugins.
    module BackupDestination
      CONTRACT_VERSION = 1

      def self.included(base) = base.extend(ClassMethods)

      module ClassMethods
        def contract_version = CONTRACT_VERSION
        def compatible_contract?(version) = Integer(version, exception: false) == CONTRACT_VERSION
        def destination_key = raise NotImplementedError, "#{name} must implement .destination_key"
        def upload(_artifact, progress: nil, **) = raise NotImplementedError, "#{name} must implement .upload"
        def verify(_remote_reference, expected_checksum:, **) = raise NotImplementedError, "#{name} must implement .verify"
        def delete(_remote_reference, reason:, **) = raise NotImplementedError, "#{name} must implement .delete"
        def materialize_local(_remote_reference, destination:, **) = raise NotImplementedError, "#{name} must implement .materialize_local"
        def health(**) = raise NotImplementedError, "#{name} must implement .health"
      end
    end
  end
end
