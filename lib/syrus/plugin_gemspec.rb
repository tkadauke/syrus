module Syrus
  # Every bundled plugin gemspec said the same twelve lines, and had drifted:
  # three variants of `spec.files`, two whitespace variants of `require_paths`,
  # `rails` vs `railties`, `required_ruby_version` in ten of thirty. None of
  # that carried information. The prose duplicated the manifest description,
  # which is the one the admin UI actually renders.
  #
  #   # plugins/throughput/throughput.gemspec
  #   require_relative "../../lib/syrus/plugin_gemspec"
  #   Syrus.plugin_gemspec(__FILE__)
  #
  # Pass a block for anything genuinely per-plugin -- an extra runtime
  # dependency is the only case among the bundled plugins.
  def self.plugin_gemspec(gemspec_path)
    root = File.dirname(gemspec_path)
    name = File.basename(gemspec_path, ".gemspec")

    Gem::Specification.new do |spec|
      spec.name    = name
      spec.version = "0.1.0"
      spec.authors = [ "Thomas Kadauke" ]
      spec.summary = "Syrus plugin: #{name}"
      spec.homepage = "https://github.com/tkadauke/syrus"

      # Directory-driven rather than declared, so adding db/ or app/ to a
      # plugin never needs a gemspec edit to go with it.
      spec.files = Dir.chdir(root) { Dir["lib/**/*", "app/**/*", "db/**/*", "config/**/*"] }
      spec.require_paths = [ "lib" ]

      spec.required_ruby_version = ">= 3.4"
      spec.add_dependency "rails", ">= 8.1"

      yield spec if block_given?
    end
  end
end
