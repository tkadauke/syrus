module Syrus
  module Plugin
    module VersionedCapability
      VERSION = "1.0"

      def compatible_version?(requested)
        requested_major, requested_minor = requested.to_s.split(".", 2).map { |part| Integer(part, 10) }
        supported_major, supported_minor = VERSION.split(".", 2).map(&:to_i)
        requested_major == supported_major && requested_minor <= supported_minor
      rescue ArgumentError, TypeError
        false
      end
    end
  end
end
