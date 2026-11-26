require_relative "boot"

require "rails/all"

# Plugin entry files call Syrus::PluginApi.syrus_plugin at *load* time, which is
# before Rails initializes and therefore before Zeitwerk and $LOAD_PATH are
# set up. It has to be on the load path and required by hand, and excluded
# from autoloading below so Zeitwerk does not manage the same constant.
$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "syrus/plugin_api"
require "syrus/host"
require "syrus/plugin_roots"
require "syrus/events"
require "syrus/plugin/manifest"
require "syrus/plugin/family"
require "syrus/plugin/family_declaration"
require "syrus/plugin/legacy_bridge"
require "syrus/plugin/family_promotion"
require "syrus/plugin_health"
require "syrus/plugin/conformance"
require "syrus/plugin/capability_provider"
require "syrus/plugin/composition"
require "syrus/plugin/context/repo_context"
require "syrus/plugin/context/workspace_context"
require "syrus/plugin/context/grader_context"
require "syrus/plugin/context/job_context"
require "syrus/plugin/context/toolkit_discovery_context"
require "syrus/plugin/context/toolkit_run_context"
require "syrus/plugin/context/toolkit_credential_context"
require "syrus/plugin/context/surface_context"
require "syrus/plugin/context/chat_integration_context"
require "syrus/plugin/context/review_contribution_context"
require "syrus/plugin/context/policy_context"
require "syrus/plugin/context/hook_context"
require "syrus/plugin/context/question_delivery_context"
require "syrus/plugin/contribution_provider"
require "syrus/plugin/context/service_context"
require "syrus/plugin/review_contributions"
require "syrus/plugin/policy"
require "syrus/plugin/lifecycle"
require "syrus/plugin/data_policy"
require "syrus/plugin/service_provider"
require "syrus/plugin/external_reviewer"
require "syrus/plugin/external_review_value"
require "syrus/plugin/families/review"
require "syrus/plugin/families/lifecycle"
require "syrus/plugin/families/data_policy"
require "syrus/plugin/families/work_policy"
require "syrus/plugin/families/question_delivery"
require "syrus/plugin/ecosystem"
require "syrus/plugin/toolkit"
require "syrus/plugin/surface"
require "syrus/plugin/chat_integration"
require "syrus/plugin/declarations"
require "syrus/plugin/declarations/providers"
require "syrus/plugin/dispatch"
require "syrus/plugin/cli_command_handler"
require "syrus/plugin/cli_command"
require "syrus/plugin_registry"
require "syrus/plugin_runtime_health"
require "syrus/plugin_invocation"
require "syrus/plugin_loader"
require_relative "../app/services/syrus_version"
require "syrus/plugin/execution_backend"
require "syrus/precompressed_asset_server"
require "syrus/response_compression"
require "syrus/server_time_zone"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)
# Plugins are application components discovered from PluginRoots, not gems in
# the bundle. Load their declarations after third-party dependencies exist and
# before the application class is built so each Rails::Engine participates in
# normal initialization.
Syrus::PluginLoader.load!

module Syrus
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    config.x.server_time_zone = Syrus::ServerTimeZone.resolve
    config.time_zone = config.x.server_time_zone.name
    config.active_record.default_timezone = :utc

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    # `deploy` is bin/deploy's implementation, not application code. It runs on
    # an operator's machine against a cluster, loads no Rails, and must not be
    # eager loaded into a running Syrus -- a web pod has no business holding
    # the code that replaces it.
    config.autoload_lib(ignore: %w[
      assets
      tasks
      generators
      deploy
      syrus/plugin_api.rb
      syrus/plugin_gemspec.rb
      syrus/plugin/test_kit.rb
      syrus/plugin/external_reviewer_contract_kit.rb
    ])

    config.generators do |g|
      g.test_framework :rspec, fixture: false, view_specs: false, helper_specs: false, routing_specs: false
    end

    plugin_roots = Syrus::PluginRoots.default
    plugin_roots.plugin_directories.each do |plugin_dir|
      migration_dir = plugin_dir.join("db/migrate")
      config.paths["db/migrate"] << migration_dir.to_s if migration_dir.directory?

      plugin_dir.glob("app/*").select { |path| path.directory? && path.glob("**/*.rb").any? }.each do |path|
        config.autoload_paths << path.to_s
        config.eager_load_paths << path.to_s
      end

      config.i18n.load_path.concat(plugin_dir.glob("config/locales/**/*.{rb,yml}").map(&:to_s))
    end

    initializer "syrus.plugin_migration_paths" do
      ActiveRecord::Migrator.migrations_paths = ActiveRecord::Tasks::DatabaseTasks.migrations_paths
    end

    initializer "syrus.precompressed_asset_server", after: "propshaft.assets_middleware" do |app|
      app.middleware.insert_before ActionDispatch::Static, Syrus::PrecompressedAssetServer,
        root: Rails.public_path,
        prefix: app.config.assets.prefix,
        headers: app.config.public_file_server.headers
    end

    config.middleware.use Rack::Deflater,
      include: Syrus::ResponseCompression::CONTENT_TYPES,
      if: Syrus::ResponseCompression.method(:eligible?)

    config.i18n.available_locales = %i[en de la]
    config.i18n.default_locale = :en

    # Active Storage's jobs subclass ActiveJob::Base directly, so they never
    # pick up ApplicationJob's `queue_as :control_plane` and default to :default
    # — a queue no worker in config/queue.yml consumes. Anything landing there
    # is never claimed (57 analyze jobs had accumulated in production, the
    # oldest 11 days), so route them onto queues that actually have workers.
    config.active_storage.queues.analysis = :low_priority_maintenance
    config.active_storage.queues.purge = :cleanup

    # Action Mailer's delivery job also subclasses ActiveJob::Base directly
    # and otherwise uses its framework-default :mailers queue, which no Syrus
    # worker consumes. Keep password-reset and invitation delivery on a queue
    # serviced by the control-plane workers.
    config.action_mailer.deliver_later_queue_name = :control_plane

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
