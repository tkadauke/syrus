require_relative "lib/spending_insights/version"

Gem::Specification.new do |spec|
  spec.name    = "spending_insights"
  spec.version = SpendingInsights::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: agent spend dashboard in the primary sidebar"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
