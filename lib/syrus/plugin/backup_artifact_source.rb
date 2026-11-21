require "syrus/plugin/versioned_capability"

module Syrus
  module Plugin
    # Versioned access to sealed backups. Consumers receive IO or opaque
    # handles, never filesystem paths. Version 1.x evolves additively.
    module BackupArtifactSource
      REQUIRED_METHODS = %i[list describe open checksum pin release_pin record_replication].freeze

      def self.included(base)
        base.extend(VersionedCapability)
        base.extend(ClassMethods)
      end

      module ClassMethods
        REQUIRED_METHODS.each do |method_name|
          define_method(method_name) do |*args, **kwargs|
            raise NotImplementedError, "#{name} must implement .#{method_name}"
          end
        end
      end
    end
  end
end
