# Restore the bundled plugin registry around each example so registry-backed
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
# Examples tagged :reset_plugin_registry opt out of the leading restore so
# their own around/before block gets a genuinely empty registry. The ensure
# restore still prevents those examples from leaking an empty registry into
# teardown or process-level hooks.
RSpec.configure do |config|
  config.around do |example|
    snapshot = Syrus::PluginRegistry.boot_snapshot
    Syrus::PluginRegistry.restore(snapshot) if snapshot && !example.metadata[:reset_plugin_registry]
    example.run
  ensure
    # Local after hooks commonly reset the registry. Restore after they finish
    # as well so teardown and process-level hooks cannot observe an empty
    # provider list between examples.
    Syrus::PluginRegistry.restore(snapshot) if snapshot
  end
end
