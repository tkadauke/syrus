# Disabled plugins are autoloadable but not eager loaded.
#
# Every bundled plugin is a Rails engine required through the Gemfile, so its
# `app/` directories join the autoload paths at boot and, in production, get
# eager loaded -- including for plugins nobody can use.
#
# Ruby cannot unload a constant tree, so "unload on disable" is not available
# and "never load it" is. This is that, and it costs nothing at enable time:
# Zeitwerk still autoloads on first reference and Syrus::Installer re-installs
# the plugin's contributions without a restart.
#
# Fails open by way of PluginRegistry.eager_load_skippable_plugin_names: if the
# plugin_records table cannot be read, nothing is skipped. Withholding code
# because a lookup failed would turn an unavailable database into missing
# behaviour.
require "syrus/plugin_eager_load"

Rails.application.config.before_eager_load do
  Syrus::PluginEagerLoad.apply!
end
