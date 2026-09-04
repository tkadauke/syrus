module SyrusClaudeAgent
  class Engine < ::Rails::Engine
    # to_prepare, not after_initialize: lib/ is autoloaded and therefore
    # reloadable, so Syrus::PluginRegistry is replaced by an empty one on every
    # code reload. after_initialize runs once per boot and would never put the
    # registrations back.  Registration is idempotent by name.
    config.to_prepare do
      SyrusClaudeAgent.register!
    end
  end
end
