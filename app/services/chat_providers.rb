module ChatProviders
  class ConfigurationError < StandardError; end

  CHAT_MODELS = {
    "claude" => [
      { value: "claude-opus-4-7", label: "Claude Opus 4.7" },
      { value: "claude-sonnet-4-6", label: "Claude Sonnet 4.6" },
      { value: "claude-haiku-4-5-20251001", label: "Claude Haiku 4.5" }
    ].freeze
  }.freeze

  def self.for(provider)
    provider_key = provider.to_s
    klass = PerformanceLogging.phase("chat_providers.lookup", provider: provider_key) do
      Syrus::Plugin::ServiceProvider.providers(:chat_provider)
        .find do |p|
          Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
            extension_point: :chat_provider, provider: p, operation: :provider_key, on_decline: false
          ) do
            p.provider_key == provider_key
          end)
        end
    end
    unless klass
      raise ConfigurationError, "Unknown chat provider: #{provider.inspect}"
    end

    klass
  end

  def self.provider_keys
    Syrus::Plugin::ServiceProvider.providers(:chat_provider).filter_map do |provider|
      Syrus::PluginInvocation.value(Syrus::PluginInvocation.call(
        extension_point: :chat_provider, provider:, operation: :provider_key, on_decline: nil
      ) { provider.provider_key })
    end
  end

  def self.display_name(provider)
    self.for(provider).display_name
  rescue ConfigurationError
    provider.to_s.titleize
  end

  def self.available_models(provider)
    CHAT_MODELS.fetch(provider.to_s, [])
  end
end
