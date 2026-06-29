module ChatProviders
  class ConfigurationError < StandardError; end

  REGISTRY = {
    "claude" => "ChatProviders::Claude"
  }.freeze

  def self.for(provider)
    class_name = REGISTRY[provider.to_s]
    unless class_name
      raise ConfigurationError, "Unknown chat provider: #{provider.inspect}"
    end

    class_name.constantize
  end
end
