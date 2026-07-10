require_relative "lib/syrus_codex_agent/version"

Gem::Specification.new do |spec|
  spec.name    = "syrus_codex_agent"
  spec.version = SyrusCodexAgent::VERSION
  spec.authors = [""]
  spec.summary = "Syrus plugin: Codex agent provider"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.1"
end
