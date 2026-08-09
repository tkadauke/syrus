Rails.application.config.after_initialize do
  # In test: reset registry state so individual examples start clean.
  # In development/production: plugins self-register via their own engine
  # initializers — no explicit list is needed here.
  if Rails.env.test?
    Syrus::PluginRegistry.reset!
  else
    Syrus::PluginRegistry.fire_boot_callbacks!
    at_exit { Syrus::PluginRegistry.fire_shutdown_callbacks! }
  end
end
