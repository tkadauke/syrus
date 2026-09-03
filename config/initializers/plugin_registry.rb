Rails.application.config.after_initialize do
  # Plugins self-register via their own engine initializers, which run before
  # this hook - no explicit list is needed here.
  #
  # In test: capture the fully-populated registry so the spec harness can
  # restore it before each example (see spec/support/bundled_plugins.rb).
  # Snapshotting rather than resetting means a newly added bundled plugin is
  # visible to specs with no harness change.
  if Rails.env.test?
    Syrus::PluginRegistry.boot_snapshot = Syrus::PluginRegistry.snapshot
  else
    Syrus::PluginRegistry.fire_boot_callbacks!
    at_exit { Syrus::PluginRegistry.fire_shutdown_callbacks! }

    # Never raises: a plugin whose dependency is missing, disabled, or
    # circular is reported and has its providers withheld, so the instance
    # boots degraded and the operator can fix it from Admin -> Plugins.
    Syrus::PluginRegistry.report_health!
  end
end
