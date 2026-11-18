Gem::Specification.new do |spec|
  spec.name = "{{PLUGIN_NAME}}"
  spec.version = "0.1.0"
  spec.summary = "{{DISPLAY_NAME}} plugin for Syrus"
  spec.authors = [ "Your name" ]
  spec.files = Dir["app/**/*", "db/**/*", "dist/**/*", "lib/**/*"]
  spec.add_dependency "rails", ">= 8.1"
  spec.metadata["requires_syrus"] = ">= {{SYRUS_VERSION}}"
end
