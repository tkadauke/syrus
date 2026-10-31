module ContainerExecution
  module EgressPolicy
    class Agy < Base
      ENDPOINT_HOSTS = %w[generativelanguage.googleapis.com oauth2.googleapis.com].freeze
      def self.provider_key = "agy"
      def provider_key = self.class.provider_key
    end
  end
end
