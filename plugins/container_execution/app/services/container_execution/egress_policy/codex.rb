module ContainerExecution
  module EgressPolicy
    class Codex < Base
      ENDPOINT_HOSTS = %w[api.openai.com chatgpt.com auth.openai.com].freeze
      def self.provider_key = "codex"
      def provider_key = self.class.provider_key
    end
  end
end
