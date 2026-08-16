require_relative "boot"

require "rails/all"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

module Syrus
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks generators])

    config.generators do |g|
      g.test_framework :rspec, fixture: false, view_specs: false, helper_specs: false, routing_specs: false
    end

    config.i18n.available_locales = %i[en de la]
    config.i18n.default_locale = :en

    # Active Storage's jobs subclass ActiveJob::Base directly, so they never
    # pick up ApplicationJob's `queue_as :control_plane` and default to :default
    # — a queue no worker in config/queue.yml consumes. Anything landing there
    # is never claimed (57 analyze jobs had accumulated in production, the
    # oldest 11 days), so route them onto queues that actually have workers.
    config.active_storage.queues.analysis = :low_priority_maintenance
    config.active_storage.queues.purge = :cleanup

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.time_zone = "Central Time (US & Canada)"
    # config.eager_load_paths << Rails.root.join("extras")
  end
end
