require_relative "lib/syrus_rails/version"

Gem::Specification.new do |spec|
  spec.name    = "syrus_rails"
  spec.version = SyrusRails::VERSION
  spec.authors = ["Thomas Kadauke"]
  spec.summary = "Ruby on Rails intelligence plugin for Syrus"
  spec.description = "Provides Rails-framework-specific capabilities to Syrus: " \
    "preview server config, schema/migration/route tooling, an MCP tool set, " \
    "and agent prompt injection. Depends on the ruby plugin for Ruby-generic " \
    "capabilities (RSpec output parsing, SimpleCov, Gemfile prepare detection)."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "railties"
end
