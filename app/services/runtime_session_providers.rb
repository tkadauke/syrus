module RuntimeSessionProviders
  class ConfigurationError < StandardError; end

  def self.all
    Syrus::PluginRegistry.providers_for(:runtime_session_provider)
  end

  def self.for(provider_key)
    klass = all.find { |provider| provider.provider_key == provider_key.to_s }
    raise ConfigurationError, "Unknown runtime session provider: #{provider_key.inspect}" unless klass

    klass
  end

  def self.detect_for(repository, config = {})
    all.find { |provider| provider.detect(repository, config) }
  end
end
