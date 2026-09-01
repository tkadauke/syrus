module SyrusClaudeAgent
  class Engine < ::Rails::Engine
    # after_initialize runs after Zeitwerk is fully active, ensuring
    # Syrus::PluginRegistry (autoloaded from lib/) is resolvable.
    config.after_initialize do
      SyrusClaudeAgent.register!
    end
  end
end
