require_relative "lib/agent_memory/version"

Gem::Specification.new do |spec|
  spec.name    = "agent_memory"
  spec.version = AgentMemory::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: durable facts agents remember between runs"

  spec.files         = Dir["lib/**/*", "app/**/*", "db/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
