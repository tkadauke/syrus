require_relative "lib/preview_tools/version"

Gem::Specification.new do |spec|
  spec.name    = "preview_tools"
  spec.version = PreviewTools::VERSION
  spec.authors = [""]
  spec.summary = "Syrus plugin: scratch-scoped preview write/edit tools for planning-mode chat"
  spec.description = "Adds a narrow write/edit tool pair, hard-jailed to a per-panel scratch " \
    "directory, plus show_preview/close_preview tools that upload the scratch directory to a " \
    "PreviewPanel -- letting a planning-mode chat agent build and preview an HTML/CSS/JS mockup " \
    "or interactive widget without ever touching the attached repository checkout."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "rails", ">= 8.1"
end
