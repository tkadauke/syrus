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
  restore_test_provider_records = proc do
    # Rails can load this support file before test database maintenance has
    # replaced the schema. Enable the providers only after that maintenance
    # finishes; doing it in an initializer creates rows that db:prepare can
    # immediately erase, leaving every registry-backed validation disabled.
    %w[claude_agent codex_agent agy_agent].each do |plugin_name|
      record = PluginRecord.find_or_create_by!(name: plugin_name)
      record.update!(enabled: true) unless record.enabled?
    end
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  config.before(:suite, &restore_test_provider_records)

  config.around do |example|
    snapshot = Syrus::PluginRegistry.boot_snapshot
    unless example.metadata[:reset_plugin_registry]
      restore_test_provider_records.call
      Syrus::PluginRegistry.restore(snapshot) if snapshot
    end
    example.run
  ensure
    # Local after hooks commonly reset the registry. Restore after they finish
    # as well so teardown and process-level hooks cannot observe an empty
    # provider list between examples.
    Syrus::PluginRegistry.restore(snapshot) if snapshot
  end
end
