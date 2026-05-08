module AgentProviders
  class ConfigurationError < StandardError; end

  def self.for(provider)
    case provider
    when "claude" then Claude
    when "codex"  then Codex
    else
      raise ConfigurationError, "Unknown agent provider: #{provider.inspect}"
    end
  end
end
