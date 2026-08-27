require_relative "lib/theming_tools/version"

Gem::Specification.new do |spec|
  spec.name    = "theming_tools"
  spec.version = ThemingTools::VERSION
  spec.authors = ["Thomas Kadauke"]
  spec.summary = "Syrus plugin: chat MCP tool for drafting and previewing custom color themes"
  spec.description = "Gives the Syrus Chat agent a preview_theme MCP tool that upserts a draft Theme row for " \
    "the chat's user and broadcasts an app event so the frontend can pop open the Style Guide page with the " \
    "candidate theme applied. The underlying Theme model stays in core (same precedent as WhiteboardSnapshot " \
    "for whiteboard_tools) -- only the tool surface and broadcast wiring live in the plugin."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "rails", ">= 8.1"
end
