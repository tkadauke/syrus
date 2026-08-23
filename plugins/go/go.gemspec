require_relative "lib/go/version"

Gem::Specification.new do |spec|
  spec.name    = "go"
  spec.version = Go::VERSION
  spec.authors = ["Thomas Kadauke"]
  spec.summary = "Go prepare-detection plugin for Syrus"
  spec.description = "Detects Go repositories via go.mod and contributes the go mod download " \
    "prepare command."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "railties"
end
