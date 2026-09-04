require "django/preview_provider"

module Django
  extend Syrus::PluginApi

  syrus_plugin "django" do
    description "Django framework intelligence: preview hosting via manage.py runserver, " \
      "migrate + fixtures seeding"
    long_description "Django layers framework-specific behavior on top of the generic Python plugin. It detects Django apps, runs previews through `manage.py runserver`, and prepares preview databases with migrations and fixture loading when configured.\n\nUse it for Django repositories where Syrus should understand framework conventions instead of treating the project as a plain Python package. It depends on the Python plugin for shared Python prepare, test, and review support."
    homepage "https://github.com/tkadauke/syrus"
    icon_url "/plugin-icons/django.svg"
    author "Thomas Kadauke"
    category "language"
    depends_on [ "python" ]
    provides preview_provider: "Django::PreviewProvider"
  end
end
