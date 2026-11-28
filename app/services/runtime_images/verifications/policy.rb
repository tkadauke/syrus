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
        overrides = configured ? JSON.parse(configured) : {}
        raise ProviderError, "#{ENV_KEY} must contain a JSON object" unless overrides.is_a?(Hash)
        admin = EnvironmentPolicy.current
        durable = {}
        blocked = admin.override("verification", "blocked_severities")
        durable["vulnerabilities"] = { "blocked_severities" => blocked } if blocked
        prohibited = admin.override("verification", "prohibited_packages")
        durable["prohibited_packages"] = prohibited if prohibited
        overrides = overrides.deep_stringify_keys.deep_merge(durable)
        Orchestrator::DEFAULT_POLICY.deep_merge(overrides.slice(*CONFIGURABLE_KEYS))
      rescue JSON::ParserError => e
        raise ProviderError, "#{ENV_KEY} is invalid JSON: #{e.message}"
      end
    end
  end
end
