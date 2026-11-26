module RuntimeImages
  module Verifications
    class Policy
      ENV_KEY = "SYRUS_RUNTIME_IMAGE_VERIFICATION_POLICY".freeze
      CONFIGURABLE_KEYS = %w[vulnerabilities prohibited_packages exemptions].freeze

      def self.current
        configured = ENV[ENV_KEY].presence
        return Orchestrator::DEFAULT_POLICY.deep_dup unless configured

        overrides = JSON.parse(configured)
        raise ProviderError, "#{ENV_KEY} must contain a JSON object" unless overrides.is_a?(Hash)

        Orchestrator::DEFAULT_POLICY.deep_merge(overrides.deep_stringify_keys.slice(*CONFIGURABLE_KEYS))
      rescue JSON::ParserError => e
        raise ProviderError, "#{ENV_KEY} is invalid JSON: #{e.message}"
      end
    end
  end
end
