require "syrus/plugin/versioned_capability"

module Syrus
  module Plugin
    # Versioned offsite destination for immutable backup artifacts. Remote
    # references are opaque to both the host and artifact source.
    module BackupDestination
      REQUIRED_METHODS = %i[upload verify delete materialize_local health].freeze

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
