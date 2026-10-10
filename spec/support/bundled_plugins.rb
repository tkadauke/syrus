module Syrus
  module SpecSupport
    module BundledPlugins
      TEST_PROVIDER_PLUGIN_NAMES = %w[claude_agent codex_agent agy_agent].freeze
      BETA_MODE_EXCLUDED_SPEC_PATHS = %r{
        \A\./spec/
        (?:
          lib/syrus/(?:installer|plugin_registry)_spec|
          models/feature_spec|
          requests/api/v1/(?:app/)?admin/(?:features|plugins)_spec
        )\.rb\z
      }x

      module_function

      def restore_test_provider_records
        # Rails can load this support file before test database maintenance has
        # replaced the schema. Enable the providers only after that maintenance
        # finishes; doing it in an initializer creates rows that db:prepare can
        # immediately erase, leaving every registry-backed validation disabled.
        # all_plugins materializes missing PluginRecord rows from the boot snapshot.
        manifests = Syrus::PluginRegistry.all_plugins

        manifests.each do |manifest|
          next unless manifest.default_enabled?

          record = PluginRecord.find_or_create_by!(name: manifest.name)
          record.update!(enabled: true) unless record.enabled?
        end

        TEST_PROVIDER_PLUGIN_NAMES.each do |plugin_name|
          record = PluginRecord.find_or_create_by!(name: plugin_name)
          record.update!(enabled: true) unless record.enabled?
        end
        Syrus::PluginRegistry.clear_plugin_record_cache!
      rescue ActiveRecord::ActiveRecordError
        # The registry itself fails open when plugin_records is unreadable.
        # Match that behavior here so database maintenance failures surface in
        # the example that needs the database, not in this global support hook.
      end

      def beta_mode_excluded?(example)
        example.metadata[:reset_plugin_registry] ||
          BETA_MODE_EXCLUDED_SPEC_PATHS.match?(example.metadata[:file_path].to_s)
      end

      def with_default_beta_mode(example)
        return yield if beta_mode_excluded?(example)

        begin
          return yield unless defined?(AppSetting) && AppSetting.respond_to?(:current)
          return yield unless AppSetting.table_exists? && AppSetting.column_names.include?("beta_mode_enabled")

          settings = AppSetting.current
          previous = settings.beta_mode_enabled?
          settings.update!(beta_mode_enabled: true) unless previous
        rescue ActiveRecord::ActiveRecordError
          return yield
        end

        yield
      ensure
        settings&.update!(beta_mode_enabled: previous) if defined?(settings) && settings && settings.beta_mode_enabled? != previous
      end
    end
  end
end

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
    Syrus::SpecSupport::BundledPlugins.restore_test_provider_records
  end

  config.before(:suite) do
    Struct.new(:metadata).new({ file_path: "./spec/support/bundled_plugins.rb" }).then do |example|
      Syrus::SpecSupport::BundledPlugins.with_default_beta_mode(example, &restore_test_provider_records)
    end
  end

  config.around do |example|
    snapshot = Syrus::PluginRegistry.boot_snapshot
    Syrus::SpecSupport::BundledPlugins.with_default_beta_mode(example) do
      unless example.metadata[:reset_plugin_registry]
        restore_test_provider_records.call
        Syrus::PluginRegistry.restore(snapshot) if snapshot
      end
      example.run
    end
  ensure
    # Local after hooks commonly reset the registry. Restore after they finish
    # as well so teardown and process-level hooks cannot observe an empty
    # provider list between examples.
    Syrus::PluginRegistry.restore(snapshot) if snapshot
  end
end
