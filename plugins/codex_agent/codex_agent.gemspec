require_relative "lib/codex_agent/version"

Gem::Specification.new do |spec|
  spec.name    = "codex_agent"
  spec.version = SyrusCodexAgent::VERSION
  spec.authors = ["Thomas Kadauke"]
  spec.summary = "Syrus plugin: Codex agent provider"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.1"
end
