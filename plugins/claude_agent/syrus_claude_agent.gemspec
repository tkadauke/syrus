require_relative "lib/syrus_claude_agent/version"

Gem::Specification.new do |spec|
  spec.name    = "syrus_claude_agent"
  spec.version = SyrusClaudeAgent::VERSION
  spec.authors = [""]
  spec.summary = "Syrus plugin: Claude agent provider"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.1"
end
