require "rails_helper"

# Statically scans each bundled plugin's source under plugins/*/lib for its
# Syrus::PluginRegistry.register(name: ...) manifest call, rather than
# relying on the runtime registry: most bundled plugins (the language/
# framework-intelligence ones especially) are deliberately NOT part of the
# shared spec/support/bundled_plugins.rb registration set, so they'd never
# show up in Syrus::PluginRegistry.all_plugins during a typical example.
# This keeps the regression coverage complete without polluting every other
# spec's registry state.
RSpec.describe "Bundled plugin categories" do
  plugin_root = Rails.root.join("plugins")
  plugin_dirs = plugin_root.children.select(&:directory?).sort_by(&:to_s)

  it "has bundled plugins to check" do
    expect(plugin_dirs).not_to be_empty
  end

  plugin_dirs.each do |dir|
    it "sets a category from Syrus::Plugin::Category on the #{dir.basename} plugin manifest" do
      manifest_file = Dir.glob(dir.join("lib/**/*.rb").to_s).find do |path|
        File.read(path).match?(/Syrus::PluginRegistry\.register\(\s*name:/)
      end

      expect(manifest_file).not_to be_nil,
        "#{dir.basename} has no Syrus::PluginRegistry.register(name: ...) manifest call under lib/"

      category = File.read(manifest_file)[/category:\s*["']([^"']+)["']/, 1]

      expect(category).to be_present,
        "#{dir.basename} plugin manifest (#{manifest_file}) has no category: set"
      expect(Syrus::Plugin::Category.valid?(category)).to be(true),
        "#{dir.basename} plugin category #{category.inspect} is not a canonical " \
        "Syrus::Plugin::Category key (#{Syrus::Plugin::Category.values.join(', ')})"
    end
  end
end
