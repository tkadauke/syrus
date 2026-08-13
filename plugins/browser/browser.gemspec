require_relative "lib/browser/version"

Gem::Specification.new do |spec|
  spec.name    = "browser"
  spec.version = SyrusBrowser::VERSION
  spec.authors = [""]
  spec.summary = "Syrus plugin: headless browser control for workflow agents"
  spec.description = "Exposes granular Playwright-backed browser MCP tools (navigate, click, fill, " \
    "snapshot, screenshot, wait_for) to workflow agents, wrapping the official @playwright/mcp " \
    "server as a bundled stdio subprocess. Navigation is hard-restricted to loopback URLs."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "rails", ">= 8.1"
end
