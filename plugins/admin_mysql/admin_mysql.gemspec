require_relative "lib/admin_mysql/version"

Gem::Specification.new do |spec|
  spec.name    = "admin_mysql"
  spec.version = AdminMysql::VERSION
  spec.authors = [ "" ]
  spec.summary = "Syrus plugin: live MySQL administration"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
