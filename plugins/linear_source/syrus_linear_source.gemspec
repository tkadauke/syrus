require_relative "lib/syrus_linear_source/version"

Gem::Specification.new do |spec|
  spec.name    = "syrus_linear_source"
  spec.version = SyrusLinearSource::VERSION
  spec.authors = [""]
  spec.summary = "Syrus plugin: Linear input source"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.1"
end
