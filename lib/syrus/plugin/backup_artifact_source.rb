require "syrus/plugin/versioned_capability"

module Syrus
  module Plugin
    # Versioned access to sealed backups. Consumers receive IO or opaque
    # handles, never filesystem paths. Version 1.x evolves additively.
    module BackupArtifactSource
      REQUIRED_METHODS = %i[list describe open checksum pin release_pin record_replication].freeze

      def self.included(base)
        base.extend(VersionedCapability)
      end
    end
  end
end
