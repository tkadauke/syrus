require "rails"

module Django
  class Engine < ::Rails::Engine
    config.after_initialize do
      # Wire up interface modules now that Zeitwerk is active and all
      # Syrus::Plugin::* constants are autoloadable from the main app's lib/.
      Django::PreviewProvider.include(Syrus::Plugin::PreviewProvider)

      Syrus::PluginRegistry.register(
        name:        "django",
        version:     Django::VERSION,
        description: "Django framework intelligence: preview hosting via manage.py runserver, " \
                      "migrate + fixtures seeding",
        homepage:    "https://github.com/tkadauke/syrus",
        author:      "Thomas Kadauke",
        icon_url:    "/plugin-icons/django.svg",
        depends_on:  [ "python" ],
        provides: {
          preview_provider: Django::PreviewProvider
        }
      )
    end
  end
end
