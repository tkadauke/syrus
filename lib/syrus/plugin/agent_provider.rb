module Syrus
  module Plugin
    # Interface module for agent provider implementations.
    #
    # Include this module in any class registered as an :agent_provider
    # extension point. The class must implement:
    #
    #   .provider_key   → String  – unique stable identifier (e.g. "claude")
    #   .display_name   → String  – shown in the settings UI
    #   .available?     → bool    – true when the provider is configured
    #   #invoke(job:, step:, workspace:, &block) – streams agent output
    module AgentProvider
    end
  end
end
