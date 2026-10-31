module ContainerExecution
  module EgressPolicy
    class Muse < Base
      ENDPOINT_HOSTS = %w[api.muse.dev].freeze
      def self.provider_key = "muse"
      def provider_key = self.class.provider_key
    end
  end
end
