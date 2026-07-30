Gem::Specification.new do |spec|
  spec.name          = "syrus_rails"
  spec.version       = "0.1.0"
  spec.authors       = ["Syrus"]
  spec.summary       = "Rails plugin for Syrus"
  spec.description   = "Provides Rails-specific capabilities to Syrus: " \
    "preview server config, RSpec output parsing, SimpleCov analysis, and agent prompt injection."
  spec.files         = Dir["lib/**/*"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.2"
end
