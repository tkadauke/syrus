require "rails_helper"

RSpec.describe Syrus::Installer, :reset_plugin_registry do
  # Installers are defined once, where their code loads. Clearing them without
  # putting them back would leave the rest of the process with no installers at
  # all — every plugin contribution silently absent from that point on.
  around do |example|
    installers = described_class.snapshot
    Syrus::PluginRegistry.reset!
    described_class.clear_registrations!
    example.run
  ensure
    described_class.restore(installers)
    Syrus::PluginRegistry.restore(Syrus::PluginRegistry.boot_snapshot) if Syrus::PluginRegistry.boot_snapshot
  end

  it "runs a registered install on the next sync" do
    log = []
    described_class.define("probe") { |scope| scope.effect("x") { log << :installed; -> { log << :disposed } } }

    described_class.sync!

    expect(log).to eq([ :installed ])
  end

  it "does not re-run while the active plugin set is unchanged" do
    runs = 0
    described_class.define("probe") { |_scope| runs += 1; nil }

    3.times { described_class.sync! }

    expect(runs).to eq(1)
  end

  # Enabling or disabling a plugin bumps the generation, which is the whole
  # signal: what was installed is torn down and installed again from the new
  # state, rather than every reader re-deriving it.
  it "disposes and reinstalls when the plugin set moves" do
    log = []
    described_class.define("probe") { |scope| scope.effect("x") { log << :install; -> { log << :dispose } } }
    described_class.sync!

    Syrus::PluginRegistry.bump_generation!
    described_class.sync!

    expect(log).to eq([ :install, :dispose, :install ])
  end

  it "replaces an installer registered under the same label rather than stacking it" do
    runs = []
    described_class.define("probe") { |_scope| runs << :first; nil }
    described_class.define("probe") { |_scope| runs << :second; nil }

    described_class.sync!

    expect(runs).to eq([ :second ])
    expect(described_class.defined_labels).to eq([ "probe" ])
  end

  # One plugin's broken install must not strand the installers after it, and
  # must not leave its own partial work in place.
  it "isolates and rolls back an install that raises" do
    log = []
    described_class.define("bad") do |scope|
      scope.effect("partial") { log << :partial; -> { log << :rolled_back } }
      raise "install failed"
    end
    described_class.define("good") { |scope| scope.effect("ok") { log << :good; nil } }

    expect { described_class.sync! }.not_to raise_error

    expect(log).to eq([ :partial, :rolled_back, :good ])
  end

  it "disposes everything on reset!" do
    log = []
    described_class.define("probe") { |scope| scope.effect("x") { -> { log << :disposed } } }
    described_class.sync!

    described_class.reset!

    expect(log).to eq([ :disposed ])
  end
end
