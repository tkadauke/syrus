require "syrus/plugin/versioned_capability"

module Syrus
  module Plugin
    # Versioned offsite destination for immutable backup artifacts. Remote
    # references are opaque to both the host and artifact source.
    module BackupDestination
      REQUIRED_METHODS = %i[upload verify delete materialize_local health].freeze

      def self.included(base)
        base.extend(VersionedCapability)
      end
    end
  end
end
