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
        return admin_policy unless configured

        overrides = JSON.parse(configured)
        raise ProviderError, "#{ENV_KEY} must contain a JSON object" unless overrides.is_a?(Hash)

        Orchestrator::DEFAULT_POLICY.deep_merge(overrides.deep_stringify_keys.slice(*CONFIGURABLE_KEYS))
      rescue JSON::ParserError => e
        raise ProviderError, "#{ENV_KEY} is invalid JSON: #{e.message}"
      end

      def self.admin_policy
        settings = EnvironmentPolicy.current.fetch("supply_chain")
        Orchestrator::DEFAULT_POLICY.deep_merge(
          "vulnerabilities" => { "blocked_severities" => settings.fetch("blocked_severities") },
          "prohibited_packages" => settings.fetch("prohibited_packages")
        )
      end
    end
  end
end
