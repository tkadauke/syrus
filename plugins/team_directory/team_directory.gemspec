require_relative "lib/team_directory/version"

Gem::Specification.new do |spec|
  spec.name    = "team_directory"
  spec.version = TeamDirectory::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: operator directory and public profile pages"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
