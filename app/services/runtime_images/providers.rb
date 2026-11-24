module RuntimeImages
  # Registry of providers keyed by RuntimeImageNamespace#provider_key.
  module Providers
    @providers = {}

    class << self
      def register(provider)
        raise ArgumentError, "provider must be a RuntimeImages::Provider" unless provider.is_a?(Provider)
        @providers[provider.key.to_s] = provider
      end

      def fetch(key)
        @providers.fetch(key.to_s) { raise NotFound, "no runtime image provider registered for #{key.inspect}" }
      end

      def unregister(key)
        @providers.delete(key.to_s)
      end

      def keys = @providers.keys
    end
  end
end
