require_relative "lib/discord/version"

Gem::Specification.new do |spec|
  spec.name    = "discord"
  spec.version = SyrusDiscord::VERSION
  spec.authors = [""]
  spec.summary = "Syrus plugin: Discord platform delivery"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.1"
  spec.add_dependency "websocket-driver", ">= 0.7"
end
