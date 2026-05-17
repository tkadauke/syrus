module AgentProviders
  class ConfigurationError < StandardError; end

  REGISTRY = {
    "claude" => "AgentProviders::Claude",
    "codex" => "AgentProviders::Codex"
  }.freeze

  def self.for(provider)
    class_name = REGISTRY[provider.to_s]
    unless class_name
      raise ConfigurationError, "Unknown agent provider: #{provider.inspect}"
    end

    class_name.constantize
  end
end
