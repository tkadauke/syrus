module ConnectedAccounts
  class ResolvedProvider
    attr_reader :key, :configuration

    def self.fetch(key)
      config = ProviderConfig.find_by(key: key)
      return new(key: key, implementation: GenericOauth2Provider, configuration: config) if config

      declaration = ProviderRegistry.fetch(key)
      new(key: key, implementation: declaration, configuration: nil)
    end

    def initialize(key:, implementation:, configuration:)
      @key = key.to_s
      @implementation = implementation
      @configuration = configuration
    end

    def call(capability, context)
      context.configuration = configuration if context.respond_to?(:configuration=)
      if @implementation.respond_to?(:call)
        @implementation.call(capability, context)
      else
        Invoker.call(provider: @implementation, capability: capability, context: context)
      end
    end

    def api_origins
      configuration ? configuration.api_origins : @implementation.api_origins
    end

    def scope_keys
      return configuration.scopes.map(&:to_s) if configuration
      @implementation.scopes.map { |scope| scope.fetch("key") }
    end
  end
end
