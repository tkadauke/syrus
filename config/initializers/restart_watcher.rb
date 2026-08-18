# Boots RestartWatcher for web/worker pods only. Mirrors the
# InstanceVersionSupervisor initializer guard (config/initializers/instance_version.rb):
# to_prepare runs after the initial Rails load (and is a no-op on dev code
# reloads since ensure_running is idempotent), and SyrusVersion.server_process?
# excludes the console, test suite, and asset compilation.
Rails.application.config.to_prepare do
  next unless SyrusVersion.server_process?

  RestartWatcher.ensure_running
end
