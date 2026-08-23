require_relative "lib/syrus_dev/version"

Gem::Specification.new do |spec|
  spec.name    = "syrus_dev"
  spec.version = SyrusDev::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: development diagnostics and tools"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
