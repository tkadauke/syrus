require "rubygems/version"
require "syrus/plugin/family"
require "syrus/plugin/composition"
require "syrus/plugin/dispatch"

module Syrus
  module Host
    CapabilityFamily = Syrus::Plugin::Family
    CapabilityDispatch = Syrus::Plugin::Dispatch
    Api = Data.define(:name, :since, :summary, :members)

    class << self
      def api(name, since:, summary:, members:)
        entry = Api.new(
          name: api_name(name),
          since: since.to_s,
          summary: summary.to_s,
          members: Array(members).map(&:to_s).freeze
        )
        validate!(entry)
        raise ArgumentError, "duplicate plugin host API: #{entry.name}" if apis.any? { |api| api.name == entry.name }

        apis << entry
        entry
      end

      def apis
        @apis ||= []
      end

      def public?(name)
        candidate = name.to_s
        apis.any? do |api|
          candidate == api.name || candidate.start_with?("#{api.name}::")
        end
      end

      # Plugins resolve their classes while the app boots, before the
      # to_prepare hook installs the aliases, so materialize one on first use.
      def const_missing(name)
        target = PublicApis::ALIASES[name] if const_defined?(:PublicApis, false)
        return super unless target

        const_set(name, target.constantize)
      end

      private

      def api_name(name)
        value = name.respond_to?(:name) ? name.name : name.to_s
        raise ArgumentError, "plugin host API name is required" if value.to_s.empty?
        unless value.to_s.start_with?("Syrus::Host::")
          raise ArgumentError, "plugin host API must live under Syrus::Host: #{value}"
        end

        value.to_s
      end

      def validate!(entry)
        version = Gem::Version.new(entry.since)
        unless entry.since.match?(/\A\d+\.\d+\.\d+(?:[.-][0-9A-Za-z.-]+)?\z/) && version.to_s == entry.since
          raise ArgumentError, "invalid release version for #{entry.name}: #{entry.since.inspect}"
        end
        raise ArgumentError, "summary is required for #{entry.name}" if entry.summary.strip.empty?
      rescue ArgumentError => error
        raise if error.message.start_with?("summary is required")

        raise ArgumentError, "invalid release version for #{entry.name}: #{entry.since.inspect}"
      end
    end
  end
end
