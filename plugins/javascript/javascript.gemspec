require_relative "lib/javascript/version"

Gem::Specification.new do |spec|
  spec.name    = "javascript"
  spec.version = JavaScript::VERSION
  spec.authors = ["Thomas Kadauke"]
  spec.summary = "Node/JS prepare-detection plugin for Syrus"
  spec.description = "Detects Node/JS (and TS) repositories via yarn/pnpm/npm lockfiles and " \
    "contributes exactly one package-manager prepare command, in priority order."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "railties"
end
