require_relative "lib/ruby/version"

Gem::Specification.new do |spec|
  spec.name    = "ruby"
  spec.version = Ruby::VERSION
  spec.authors = ["Syrus"]
  spec.summary = "Ruby-generic intelligence plugin for Syrus"
  spec.description = "Provides Ruby-generic capabilities to Syrus (not specific to Rails): " \
    "RSpec grader failure detail, SimpleCov coverage analysis, and Gemfile prepare detection."
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "railties"
end
