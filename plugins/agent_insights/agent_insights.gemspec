require_relative "lib/agent_insights/version"

Gem::Specification.new do |spec|
  spec.name    = "agent_insights"
  spec.version = AgentInsights::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: read-only agent surveys that propose follow-up work"

  spec.files         = Dir["lib/**/*", "app/**/*", "db/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
