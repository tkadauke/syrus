require "rails_helper"

# Statically scans each bundled plugin's source under plugins/*/lib for its
# syrus_plugin declaration, rather than relying on the runtime registry: most bundled plugins (the language/
# framework-intelligence ones especially) are deliberately NOT part of the
# shared spec/support/bundled_plugins.rb registration set, so they'd never
# show up in Syrus::PluginRegistry.all_plugins during a typical example.
# This keeps the regression coverage complete without polluting every other
# spec's registry state.
RSpec.describe "Bundled plugin manifest metadata" do
  plugin_root = Rails.root.join("plugins")
  all_dirs = plugin_root.children.select(&:directory?).sort_by(&:to_s)

  # A plugin is a Ruby gem, and the gemspec is what makes it one. A directory
  # may also carry only a Go CLI module (plugins/<name>/cli) ahead of the Ruby
  # extraction -- that is not a gem and has no manifest to check.
  plugin_dirs = all_dirs.select { |dir| Dir.glob(dir.join("*.gemspec").to_s).any? }
  cli_only_dirs = all_dirs - plugin_dirs

  it "has bundled plugins to check" do
    expect(plugin_dirs).not_to be_empty
  end

  # Without this, a plugin whose gemspec went missing would silently drop out
  # of every example above instead of failing.
  it "has no directory that is neither a gem nor a plugin-owned CLI module" do
    strays = cli_only_dirs.reject { |dir| dir.join("cli/go.mod").exist? }

    expect(strays.map { |dir| dir.basename.to_s }).to be_empty,
      "plugins/ entries with no gemspec and no cli/go.mod: #{strays.map(&:to_s).join(', ')}"
  end

  plugin_dirs.each do |dir|
    it "sets a category, author, and its own icon on the #{dir.basename} plugin manifest" do
      manifest_file = Dir.glob(dir.join("lib/**/*.rb").to_s).find do |path|
        File.read(path).match?(/^\s*syrus_plugin\s+["']/)
      end

      expect(manifest_file).not_to be_nil,
        "#{dir.basename} has no syrus_plugin declaration under lib/"

      category = File.read(manifest_file)[/^\s*category\s+["']([^"']+)["']/, 1]

      expect(category).to be_present,
        "#{dir.basename} plugin manifest (#{manifest_file}) has no category: set"
      expect(Syrus::Plugin::Category.valid?(category)).to be(true),
        "#{dir.basename} plugin category #{category.inspect} is not a canonical " \
        "Syrus::Plugin::Category key (#{Syrus::Plugin::Category.values.join(', ')})"

      source = File.read(manifest_file)

      author = source[/^\s*author\s+["']([^"']+)["']/, 1]
      expect(author).to be_present,
        "#{dir.basename} plugin manifest has no author: set"

      icon = source[/^\s*icon_url\s+["']([^"']+)["']/, 1]
      expect(icon).to be_present,
        "#{dir.basename} plugin manifest has no icon_url: set"

      # The generic standard is the payload's fallback for a plugin that has
      # not been given a face yet, not something a bundled plugin should ship.
      expect(icon).not_to end_with("/spqr_eagle.svg"),
        "#{dir.basename} still uses the generic fallback icon; give it its own"

      expect(Rails.root.join("public", icon.delete_prefix("/"))).to exist,
        "#{dir.basename} points at #{icon}, which does not exist under public/"
    end
  end
end
