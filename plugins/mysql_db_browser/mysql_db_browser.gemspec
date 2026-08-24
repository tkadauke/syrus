require_relative "lib/mysql_db_browser/version"

Gem::Specification.new do |spec|
  spec.name    = "mysql_db_browser"
  spec.version = MysqlDbBrowser::VERSION
  spec.authors = [ "Thomas Kadauke" ]
  spec.summary = "Syrus plugin: MySQL DB browser"

  spec.files         = Dir["lib/**/*", "app/**/*"]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "rails", ">= 8.1"
end
