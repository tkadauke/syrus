require_relative "lib/python/version"

Gem::Specification.new do |spec|
  spec.name    = "python"
  spec.version = Python::VERSION
  spec.authors = ["Syrus"]
  spec.summary = "Python-generic intelligence plugin for Syrus"
  spec.description = "Provides Python-generic capabilities to Syrus: uv/poetry/pip prepare " \
    "detection, pytest JSON-report grader failure detail, and a light venv/uv activation " \
    "prompt reminder."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "railties"
end
