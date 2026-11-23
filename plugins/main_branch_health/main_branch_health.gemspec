Gem::Specification.new do |spec|
  spec.name = "main_branch_health"
  spec.version = "0.1.0"
  spec.summary = "Main-branch health storage and settings for Syrus"
  spec.authors = [ "Thomas Kadauke" ]
  spec.files = Dir["app/**/*", "db/**/*", "dist/**/*", "lib/**/*"]
  spec.add_dependency "rails", ">= 8.1"
  spec.metadata["requires_syrus"] = ">= 0.1.0"
end
