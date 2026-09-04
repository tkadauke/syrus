require_relative "lib/global_search/version"

Gem::Specification.new do |spec|
  spec.name    = "global_search"
  spec.version = GlobalSearch::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: unified search across Jobs, Epics, chats and plugin-contributed types"

  spec.files         = Dir["lib/**/*", "app/**/*", "db/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
