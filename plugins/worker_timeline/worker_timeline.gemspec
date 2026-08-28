require_relative "lib/worker_timeline/version"

Gem::Specification.new do |spec|
  spec.name    = "worker_timeline"
  spec.version = WorkerTimeline::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: multi-lane worker activity timeline"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
