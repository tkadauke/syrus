require "syrus/plugin/versioned_capability"

module Syrus
  module Plugin
    # Versioned offsite destination for immutable backup artifacts. Remote
    # references are opaque to both the host and artifact source.
    module BackupDestination
      REQUIRED_METHODS = %i[upload verify delete materialize_local health].freeze
      # Optional, added in 1.x: `identity` is the destination_identity this
      # destination pins artifacts under (nil when it does not say), and
      # `configured?` is whether it could upload right now. An artifact source
      # releases an expired upload only when no enabled destination that
      # declares its identity, configured, claims it.
      OPTIONAL_METHODS = %i[identity configured?].freeze

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

        def identity = nil
        def configured? = true
      end
    end
  end
end
