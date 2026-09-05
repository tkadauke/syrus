require "rails_helper"

# `always` effects exist so disabling a plugin does not orphan the rows it
# wrote -- a deleted repository still has to take them with it. A plugin that
# was never enabled here wrote none, so running its cleanup only loads its
# models for nothing.
RSpec.describe "Syrus::Installer ever_enabled scope", :reset_plugin_registry do
  around do |ex|
    Syrus::PluginRegistry.reset!
    Syrus::Installer.reset!
    ex.run
    Syrus::PluginRegistry.reset!
    Syrus::Installer.reset!
  end

  def install_counts
    counts = Hash.new(0)
    Syrus::Installer.define("p:while_enabled", plugin: "p", requires: :enabled) { counts[:while_enabled] += 1 }
    Syrus::Installer.define("p:always", plugin: "p", requires: :ever_enabled) { counts[:always] += 1 }
    counts
  end

  def with_plugin(enabled:, ever_enabled:)
    allow(Syrus::PluginRegistry).to receive(:all_plugins)
      .and_return([ instance_double(Syrus::Plugin::Manifest, name: "p", enabled?: enabled) ])
    allow(Syrus::PluginRegistry).to receive(:ever_enabled_plugin_names)
      .and_return(ever_enabled ? Set["p"] : Set.new)
  end

  it "runs both when the plugin is enabled" do
    counts = install_counts
    with_plugin(enabled: true, ever_enabled: true)

    Syrus::Installer.sync!

    expect(counts).to eq(while_enabled: 1, always: 1)
  end

  # Disabled but previously on: the rows exist, so cleanup must still be wired.
  it "runs only the always effect for a plugin that was enabled before" do
    counts = install_counts
    with_plugin(enabled: false, ever_enabled: true)

    Syrus::Installer.sync!

    expect(counts).to eq(always: 1)
  end

  it "runs neither for a plugin that was never enabled here" do
    counts = install_counts
    with_plugin(enabled: false, ever_enabled: false)

    Syrus::Installer.sync!

    expect(counts).to be_empty
  end
end
