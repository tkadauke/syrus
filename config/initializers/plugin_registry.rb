Rails.application.config.after_initialize do
  # In test: reset registry state so individual examples start clean.
  # In development/production: plugins self-register via their own engine
  # initializers — no explicit list is needed here.
  Syrus::PluginRegistry.reset! if Rails.env.test?
end
