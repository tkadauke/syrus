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
  engines = Rails.root.glob("plugins/*/lib/*/engine.rb")

  it "finds the bundled plugin engines" do
    expect(engines.size).to be >= 25
  end

  engines.each do |engine|
    relative = engine.relative_path_from(Rails.root)

    it "registers from to_prepare, not after_initialize (#{relative})" do
      source = engine.read
      registers = source.include?("register!") || source.include?("PluginRegistry.register")
      next unless registers

      hook = source[/config\.(to_prepare|after_initialize) do/, 1]

      expect(hook).to eq("to_prepare"),
        "#{relative} registers in config.#{hook}, which runs once per boot. " \
        "The registry is wiped on every reload, so the plugin would vanish in development."
    end
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
