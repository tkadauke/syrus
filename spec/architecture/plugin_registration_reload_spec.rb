require "rails_helper"

# lib/ is autoloaded (config.autoload_lib), so Syrus::PluginRegistry is itself a
# reloadable constant: every dev code reload replaces it with an empty registry.
# Registration therefore has to run on `to_prepare`, which fires after each
# reload, and not on `after_initialize`, which fires once per boot.
#
# When this was wrong, the first file save in `bin/dev` silently unregistered
# all 30 bundled plugins -- no error, just an app with no agent providers, no
# source control, and an empty sidebar.
RSpec.describe "Plugin registration survives code reloading" do
  plugin_files = Rails.root.glob("plugins/*/lib/*.rb")

  it "finds the bundled plugin declarations" do
    expect(plugin_files.size).to be >= 25
  end

  plugin_files.each do |file|
    relative = file.relative_path_from(Rails.root)

    it "declares itself through Syrus::PluginApi (#{relative})" do
      source = file.read

      expect(source).to include("extend Syrus::PluginApi"),
        "#{relative} does not use the plugin API, so nothing guarantees when it registers."
      expect(source).to match(/^  syrus_plugin "/),
        "#{relative} extends the API but never calls syrus_plugin."
    end
  end

  it "hooks registration on to_prepare for every plugin at once" do
    # The one place the timing decision lives, now that no plugin makes it.
    expect(Rails.root.join("lib/syrus/plugin_api.rb").read).to include("config.to_prepare")
  end

  it "does not leave a hand-written engine or version file behind" do
    leftovers = Rails.root.glob("plugins/*/lib/*/{engine,version}.rb")

    expect(leftovers).to eq([])
  end

  it "keeps one manifest per name when the same plugin registers again" do
    snapshot = Syrus::PluginRegistry.snapshot

    begin
      2.times do
        Syrus::PluginRegistry.register(
          name: "reload_probe", version: "1.0.0", provides: {}
        )
      end

      matching = Syrus::PluginRegistry.all_plugins.count { |m| m.name == "reload_probe" }
      expect(matching).to eq(1)
    ensure
      Syrus::PluginRegistry.restore(snapshot)
    end
  end

  # A second class in one file is invisible until something references it
  # during a reload: Zeitwerk only manages the constant the path names, so the
  # other one is re-opened against a superclass from the previous generation and
  # raises `superclass mismatch`. Both bundled offenders were only found by
  # moving registration onto to_prepare.
  it "defines one top-level constant per plugin source file" do
    offenders = Rails.root.glob("plugins/*/app/**/*.rb").filter_map do |path|
      constants = path.read.scan(/^  (?:class|module) ([A-Z]\w*)/).flatten
      next if constants.size <= 1

      "#{path.relative_path_from(Rails.root)} defines #{constants.join(', ')}"
    end

    expect(offenders).to eq([])
  end
end
