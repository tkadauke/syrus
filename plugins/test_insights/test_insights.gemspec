require_relative "lib/test_insights/version"

Gem::Specification.new do |spec|
  spec.name    = "test_insights"
  spec.version = TestInsights::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: flaky, failing, and slow test tracking from grader output"

  spec.files         = Dir["lib/**/*", "app/**/*", "db/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
