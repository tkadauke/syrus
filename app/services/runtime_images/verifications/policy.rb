module RuntimeImages
  module Verifications
    class Policy
      ENV_KEY = "SYRUS_RUNTIME_IMAGE_VERIFICATION_POLICY".freeze
      CONFIGURABLE_KEYS = %w[vulnerabilities prohibited_packages exemptions image evidence_ttl_seconds].freeze

      def self.digest(policy = current)
        canonical = canonicalize(policy)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical))}"
      end

      def self.canonicalize(value)
        return value.stringify_keys.sort.to_h { |key, item| [ key, canonicalize(item) ] } if value.is_a?(Hash)
        return value.map { |item| canonicalize(item) } if value.is_a?(Array)

        value
      end

      def self.current
        configured = ENV[ENV_KEY].presence
        unless configured
          admin = CoworkerEnvironmentPolicy.current.fetch("verification")
          return Orchestrator::DEFAULT_POLICY.deep_merge(
            "vulnerabilities" => { "blocked_severities" => admin.fetch("blocked_severities") },
            "prohibited_packages" => admin.fetch("prohibited_packages")
          )
        end

        overrides = JSON.parse(configured)
        raise ProviderError, "#{ENV_KEY} must contain a JSON object" unless overrides.is_a?(Hash)

        Orchestrator::DEFAULT_POLICY.deep_merge(overrides.deep_stringify_keys.slice(*CONFIGURABLE_KEYS))
      rescue JSON::ParserError => e
        raise ProviderError, "#{ENV_KEY} is invalid JSON: #{e.message}"
      end
    end
  end
end
