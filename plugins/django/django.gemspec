require_relative "lib/django/version"

Gem::Specification.new do |spec|
  spec.name    = "django"
  spec.version = Django::VERSION
  spec.authors = ["Syrus"]
  spec.summary = "Django framework intelligence plugin for Syrus"
  spec.description = "Provides Django-framework-specific capabilities to Syrus: preview " \
    "server config via manage.py runserver, and migrate-based seeding with a documented " \
    "fixtures/seed convention. Depends on the python plugin for Python-generic " \
    "capabilities (prepare detection, pytest grader detail)."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "railties"
end
