require_relative "lib/syrus_core_tools/version"

Gem::Specification.new do |spec|
  spec.name    = "syrus_core_tools"
  spec.version = SyrusCoreTools::VERSION
  spec.authors = ["Syrus"]
  spec.summary = "Bundled MCP tool set for the Syrus workflow sidecar."

  spec.files         = Dir["{lib,app}/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.0"
end
