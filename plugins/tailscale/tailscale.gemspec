require_relative "lib/tailscale/version"

Gem::Specification.new do |spec|
  spec.name    = "tailscale"
  spec.version = Tailscale::VERSION
  spec.authors = [ "" ]
  spec.summary = "Syrus plugin: Tailscale connectivity"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
