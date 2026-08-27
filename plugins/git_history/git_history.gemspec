require_relative "lib/git_history/version"

Gem::Specification.new do |spec|
  spec.name    = "git_history"
  spec.version = GitHistory::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: full git history attribution"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
  spec.add_dependency "puma", ">= 5.0"
end
