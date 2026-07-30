require_relative "lib/syrus_rails/version"

Gem::Specification.new do |spec|
  spec.name    = "syrus_rails"
  spec.version = SyrusRails::VERSION
  spec.authors = ["Syrus"]
  spec.summary = "Ruby on Rails intelligence plugin for Syrus"
  spec.homepage = "https://github.com/tkadauke/syrus"

  spec.files         = Dir["lib/**/*.rb"]
  spec.require_paths = ["lib"]

  spec.required_ruby_version = ">= 3.4"

  spec.add_dependency "railties"
end
