require_relative "lib/github_source/version"

Gem::Specification.new do |spec|
  spec.name    = "github_source"
  spec.version = SyrusGithubSource::VERSION
  spec.authors = ["Thomas Kadauke"]
  spec.summary = "Syrus plugin: GitHub input source"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.1"
end
