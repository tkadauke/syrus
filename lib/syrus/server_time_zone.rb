# frozen_string_literal: true

require "tzinfo"

module Syrus
  class ServerTimeZone
    DEFAULT = "Etc/UTC"

    Resolution = Data.define(:name, :source)

    class << self
      def resolve(environment = ENV)
        explicit = environment["SYRUS_TIME_ZONE"].presence
        return Resolution.new(name: validate!(explicit, variable: "SYRUS_TIME_ZONE"), source: "SYRUS_TIME_ZONE") if explicit

        process_zone = environment["TZ"].presence
        return Resolution.new(name: process_zone, source: "TZ") if process_zone && valid?(process_zone)

        Resolution.new(name: DEFAULT, source: "default")
      end

      def valid?(name)
        TZInfo::Timezone.get(name)
        true
      rescue TZInfo::InvalidTimezoneIdentifier
        false
      end

      def validate!(name, variable: "time zone")
        return name if valid?(name)

        raise ArgumentError, "#{variable} must be a valid IANA time zone identifier (received #{name.inspect})"
      end
    end
  end
end
