Rails.application.config.after_initialize do
  # Core providers use the same extension point plugins use, and are
  # registered before the test boot snapshot is captured below.
  Syrus::PluginRegistry.register_direct(:slug_type, SlugRefs::Types::Job)
  Syrus::PluginRegistry.register_direct(:slug_type, SlugRefs::Types::Epic)
  Syrus::PluginRegistry.register_direct(:slug_type, SlugRefs::Types::Chat)
  Syrus::PluginRegistry.register_direct(:slug_type, SlugRefs::Types::Workflow)
  Syrus::PluginRegistry.register_direct(:work_gate, MainBranchHealthProvider)
  Syrus::PluginRegistry.register_direct(:system_alert_provider, MainBranchHealthProvider)
  Syrus::PluginRegistry.register_direct(:repair_classifier, MainBranchHealthProvider)

  # Plugins self-register via their own engine initializers, which run before
  # this hook - no explicit list is needed here.
  #
  # In test: capture the fully-populated registry so the spec harness can
  # restore it before each example (see spec/support/bundled_plugins.rb).
  # Snapshotting rather than resetting means a newly added bundled plugin is
  # visible to specs with no harness change.
  if Rails.env.test?
    Syrus::PluginRegistry.boot_snapshot = Syrus::PluginRegistry.snapshot
    safety = Syrus::PluginBootSafety.default
    safety.mark_good!(Syrus::PluginLoader.plugins_by_name.to_h.values, attempt_id: Syrus::PluginLoader.boot_attempt_id)
  else
    Syrus::PluginRegistry.fire_boot_callbacks!
    at_exit { Syrus::PluginRegistry.fire_shutdown_callbacks! }

    # Never raises: a plugin whose dependency is missing, disabled, or
    # circular is reported and has its providers withheld, so the instance
    # boots degraded and the operator can fix it from Admin -> Plugins.
    Syrus::PluginRegistry.report_health!

    # Promotion is intentionally delayed: reaching after_initialize is not a
    # good boot if the process immediately dies in a crash loop.
    Thread.new do
      sleep Integer(ENV.fetch("SYRUS_BOOT_SUCCESS_AFTER_SECONDS", "60"), 10)
      plugins = Syrus::PluginLoader.plugins_by_name.to_h.values
      safety = Syrus::PluginBootSafety.default
      safety.mark_good!(plugins.reject { |plugin| safety.skip_reason(plugin) }, attempt_id: Syrus::PluginLoader.boot_attempt_id)
    rescue StandardError => e
      Rails.logger.error("[PluginBootSafety] could not mark boot good: #{e.class}: #{e.message}")
    end
  end
end
