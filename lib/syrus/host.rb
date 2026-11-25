require "rubygems/version"

module Syrus
  module Host
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

      # Plugin classes are loaded while the application boots, before the
      # to_prepare hook installs the facade aliases. Resolve a declared alias on
      # first reference so boot-time plugin code sees the same constant the hook
      # installs later.
      def const_missing(name)
        require "syrus/host/public_apis"
        target = PublicApis::ALIASES[name]
        return super unless target

        const_set(name, target.constantize)
      end

      def public?(name)
        candidate = name.to_s
        apis.any? do |api|
          candidate == api.name || candidate.start_with?("#{api.name}::")
        end
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
