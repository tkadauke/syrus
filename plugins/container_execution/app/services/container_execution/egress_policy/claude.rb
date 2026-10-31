module ContainerExecution
  module EgressPolicy
    class Claude < Base
      ENDPOINT_HOSTS = %w[api.anthropic.com].freeze
      def self.provider_key = "claude"
      def provider_key = self.class.provider_key
    end
  end
end
