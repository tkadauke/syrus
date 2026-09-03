require_relative "lib/throughput/version"

Gem::Specification.new do |spec|
  spec.name    = "throughput"
  spec.version = Throughput::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: repository delivery throughput metrics panel"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
