require_relative "lib/design_docs/version"

Gem::Specification.new do |spec|
  spec.name    = "design_docs"
  spec.version = DesignDocs::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: collaborative design documents"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
