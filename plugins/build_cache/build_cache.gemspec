require_relative "lib/build_cache/version"

Gem::Specification.new do |spec|
  spec.name    = "build_cache"
  spec.version = BuildCache::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: shared sccache compiler cache wiring, stats, and admin controls"

  spec.files         = Dir["lib/**/*", "app/**/*", "db/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
