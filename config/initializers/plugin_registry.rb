Rails.application.config.after_initialize do
  # Plugins self-register via their own engine initializers, which run before
  # this hook - no explicit list is needed here.
  #
  # In test: capture the fully-populated registry so the spec harness can
  # restore it before each example (see spec/support/bundled_plugins.rb).
  # Snapshotting rather than resetting means a newly added bundled plugin is
  # visible to specs with no harness change.
  if Rails.env.test?
    # claude_agent/codex_agent/agy_agent default to disabled on a brand-new
    # PluginRecord (fresh installs must opt in through onboarding), but the
    # test suite assumes an already-connected instance the same way a real
    # developer's persisted dev.db would be after onboarding once. A fresh
    # test database has no such history, so force these primary providers
    # enabled here rather than making every spec that touches an agent
    # provider carry its own PluginRecord setup (the way muse_agent-specific
    # specs already do for a plugin that's genuinely meant to stay opt-in).
    begin
      %w[claude_agent codex_agent agy_agent].each do |plugin_name|
        record = PluginRecord.find_or_create_by!(name: plugin_name)
        record.update!(enabled: true) unless record.enabled?
      end
    rescue ActiveRecord::ActiveRecordError
      # Table/database not available yet (e.g. db:purge/db:load_config
      # booting the environment before the schema exists). Nothing to
      # force-enable yet; the real plugin registration hits this same
      # rescue in Syrus::PluginRegistry.upsert_plugin_record! for the
      # same reason.
    end

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
