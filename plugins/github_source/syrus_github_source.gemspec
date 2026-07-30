require_relative "lib/syrus_github_source/version"

Gem::Specification.new do |spec|
  spec.name    = "syrus_github_source"
  spec.version = SyrusGithubSource::VERSION
  spec.authors = [""]
  spec.summary = "Syrus plugin: GitHub input source"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.1"
end
