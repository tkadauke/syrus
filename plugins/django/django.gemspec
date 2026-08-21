require_relative "lib/django/version"

Gem::Specification.new do |spec|
  spec.name    = "django"
  spec.version = Django::VERSION
  spec.authors = ["Syrus"]
  spec.summary = "Django framework intelligence plugin for Syrus"
  spec.description = "Provides Django-framework-specific capabilities to Syrus: a :preview_provider " \
    "that boots manage.py runserver, migrates and seeds the database, and depends on the python " \
    "plugin for Python-generic prepare detection."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "railties"
end
