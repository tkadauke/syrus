module Syrus
  module Plugin
    # Provisional v1 service contract for immutable recovery artifacts.
    # Consumers receive streams and safe metadata, never filesystem paths.
    module BackupArtifactSource
      CONTRACT_VERSION = 1

      def self.included(base) = base.extend(ClassMethods)

      module ClassMethods
        def contract_version = CONTRACT_VERSION
        def compatible_contract?(version) = Integer(version, exception: false) == CONTRACT_VERSION
        def source_key = raise NotImplementedError, "#{name} must implement .source_key"
        def list(**) = raise NotImplementedError, "#{name} must implement .list"
        def describe(_backup_id, **) = raise NotImplementedError, "#{name} must implement .describe"
        def open(_backup_id, **) = raise NotImplementedError, "#{name} must implement .open"
        def checksum(_backup_id, **) = raise NotImplementedError, "#{name} must implement .checksum"
        def pin(_backup_id, owner:, **) = raise NotImplementedError, "#{name} must implement .pin"
        def release_pin(_backup_id, owner:, **) = raise NotImplementedError, "#{name} must implement .release_pin"
        def record_replication(_backup_id, destination:, result:, **) = raise NotImplementedError, "#{name} must implement .record_replication"
      end
    end
  end
end
