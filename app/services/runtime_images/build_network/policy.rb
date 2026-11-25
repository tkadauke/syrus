require "digest"

module RuntimeImages
  module BuildNetwork
    # An immutable snapshot of the enabled allowlist rules. A build takes one
    # snapshot when it starts, so an administrator's edit applies to the next
    # build and never changes the rules under a running one.
    class Policy
      Rule = Data.define(:source_class, :host, :port, :path_prefix, :ecosystem, :required) do
        def source = SourceClass.for(source_class)
      end

      def self.current
        new(RuntimeImageBuildNetworkRule.enabled.order(:id).map do |rule|
          Rule.new(source_class: rule.source_class, host: rule.host, port: rule.port, path_prefix: rule.path_prefix,
                   ecosystem: rule.ecosystem, required: rule.required)
        end)
      end

      attr_reader :rules

      def initialize(rules)
        @rules = rules.freeze
      end

      def empty? = rules.empty?

      # The rules this build was bound to, as stored evidence.
      def snapshot = rules.map { |rule| rule.to_h.stringify_keys }

      def digest
        "sha256:#{Digest::SHA256.hexdigest(rules.map(&:to_h).map(&:to_json).sort.join("\n"))}"
      end

      # +path+ is nil for a CONNECT tunnel. Never raises: every outcome is a
      # Decision carrying the reason, so the proxy can report and audit it.
      def decide(host:, port:, path: nil)
        canonical = HostName.normalize(host)
        return Decision.deny("literal_ip_forbidden", host: host.to_s, port: port) if HostName.literal?(host)
        return Decision.deny("invalid_host", host: host.to_s, port: port) unless canonical
        return Decision.deny("invalid_port", host: canonical, port: port) unless port.is_a?(Integer) && (1..65_535).cover?(port)

        candidates = rules.select { |rule| rule.source.matches?(rule, host: canonical, port: port, path: path) }
        allowed = candidates.reject { |rule| displaced?(rule) }
        return Decision.allow(allowed.first, host: canonical, port: port) if allowed.any?
        return Decision.deny("internal_mirror_required", host: canonical, port: port) if candidates.any?

        Decision.deny(denial_reason(canonical, port, path), host: canonical, port: port)
      end

      private

      # A required internal mirror displaces the public sources of its
      # ecosystem (all of them when the mirror names none).
      def displaced?(rule)
        return false unless rule.source.displaced_by_required_mirror?

        rules.any? do |mirror|
          mirror.required && mirror.source.requirable? && (mirror.ecosystem.blank? || mirror.ecosystem == rule.ecosystem)
        end
      end

      def denial_reason(host, port, path)
        if path.nil? && rules.any? { |rule| rule.source.path_scoped? && rule.host == host && rule.port == port }
          return "path_not_inspectable"
        end
        return "undeclared_package_registry" if SourceClass::LanguageRegistry::KNOWN_HOSTS.key?(host)

        "not_allowlisted"
      end
    end
  end
end
