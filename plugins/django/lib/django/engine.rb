require "rails"

module Django
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up the interface module now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      Django::PreviewProvider.include(Syrus::Plugin::PreviewProvider)

      Syrus::PluginRegistry.register(
        name:        "django",
        version:     Django::VERSION,
        description: "Django framework intelligence: preview hosting via manage.py " \
                     "runserver, migrate-based seeding with a documented fixtures/seed " \
                     "convention",
        homepage:    "https://github.com/tkadauke/syrus",
        depends_on:  [ "python" ],
        provides: {
          preview_provider: Django::PreviewProvider
        }
      )
    end
  end
end
