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

      # The names this hook has to see enabled, derived from the boot snapshot
      # and therefore constant for the life of the process. Computing it costs
      # one all_plugins call; caching it is what lets the per-example check
      # below avoid paying that call again.
      def required_enabled_plugin_names
        return @required_enabled_plugin_names if @required_enabled_plugin_names

        manifests = Syrus::PluginRegistry.all_plugins
        # An empty registry means this ran while an example had reset it, not
        # that the instance has no plugins: the around hook calls this before
        # it restores the boot snapshot. Don't memoize that -- return nil and
        # let the caller fall through to the full restore loop.
        return nil if manifests.empty?

        @required_enabled_plugin_names =
          (manifests.select(&:default_enabled?).map(&:name) + TEST_PROVIDER_PLUGIN_NAMES).uniq.to_set
      rescue ActiveRecord::ActiveRecordError
        nil
      end

      # True when every required plugin is already enabled, in one query.
      def required_records_already_enabled?
        required = required_enabled_plugin_names
        return false if required.nil?

        required.subset?(PluginRecord.where(enabled: true).pluck(:name).to_set)
      rescue ActiveRecord::ActiveRecordError
        false
      end

      def restore_test_provider_records
        # Fast path, and the reason this method is not simply the loop below.
        #
        # The loop is idempotent: it enables about thirty plugins that the
        # before(:suite) hook has already enabled, and transactional fixtures
        # roll back anything an example did to those rows. So on the
        # overwhelming majority of examples it rediscovers a state that was
        # already true -- at the cost of an all_plugins call plus a
        # find_or_create_by per plugin, with the cache cleared at the end so
        # the next example's all_plugins is cold again.
        #
        # Measured: 200 trivial examples took 10.53s with this hook and 0.205s
        # without it -- 51ms of the 52.6ms per-example harness overhead, or
        # about 35% of the whole suite's wall clock, spent restoring a registry
        # that the example never touches. The same all_plugins call is logged at
        # 1.1-1.4s in production.
        #
        # Verifying the state costs one query. Do that, and only fall through to
        # the restore when something actually has to change. The cache is still
        # cleared either way, so an example that rolled back a PluginRecord
        # write cannot leave a stale cache behind for the next one.
        if required_records_already_enabled?
          Syrus::PluginRegistry.clear_plugin_record_cache!
          return
        end

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
