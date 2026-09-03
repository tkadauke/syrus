# Restore the bundled plugin registry before each example so registry-backed
# model validations, settings payloads, and provider lookups behave the way
# they do at runtime.
#
# config/initializers/plugin_registry.rb snapshots the registry in test mode
# once boot has finished and every bundled plugin engine has self-registered.
# Restoring that snapshot here means the harness carries no hand-maintained
# list of plugins: adding a bundled plugin makes it visible to specs with no
# change to this file, and an inlined manifest can never drift from the real
# one.
#
# Examples tagged :reset_plugin_registry opt out so their own around/before
# block gets a genuinely empty registry. RSpec hook ordering is around-pre →
# before → example, so this hook would otherwise fire after the reset and
# repopulate the registry before the example body runs.
RSpec.configure do |config|
  config.before do |example|
    next if example.metadata[:reset_plugin_registry]

    snapshot = Syrus::PluginRegistry.boot_snapshot
    next if snapshot.nil?

    Syrus::PluginRegistry.restore(snapshot)
  end
end
