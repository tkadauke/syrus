require "rails_helper"

RSpec.describe Syrus::Plugin::EffectRegistry do
  after { described_class.reset! }

  it "drains a plugin's cleanups in reverse registration order" do
    log = []
    described_class.register("probe") { log << :first }
    described_class.register("probe") { log << :second }

    described_class.drain!("probe")

    expect(log).to eq([ :second, :first ])
  end

  it "drains only the named plugin" do
    log = []
    described_class.register("a") { log << :a }
    described_class.register("b") { log << :b }

    described_class.drain!("a")

    expect(log).to eq([ :a ])
  end

  it "keeps draining after a cleanup raises" do
    log = []
    described_class.register("probe") { log << :ok }
    described_class.register("probe") { raise "cleanup failed" }

    expect { described_class.drain!("probe") }.not_to raise_error
    expect(log).to eq([ :ok ])
  end

  it "accepts new effects after a drain" do
    log = []
    described_class.register("probe") { log << :before }
    described_class.drain!("probe")

    described_class.register("probe") { log << :after }
    described_class.drain!("probe")

    expect(log).to eq([ :before, :after ])
  end

  it "is a no-op for a plugin that registered nothing" do
    expect { described_class.drain!("never_registered") }.not_to raise_error
  end

  # The lifetime distinction that keeps this separate from Syrus::Installer:
  # another plugin toggling re-applies installs, and must not touch a running
  # plugin's lifecycle effects.
  it "survives an installer re-apply" do
    log = []
    described_class.register("probe") { log << :disposed }

    Syrus::PluginRegistry.bump_generation!
    Syrus::Installer.sync!

    expect(log).to be_empty

    described_class.drain!("probe")
    expect(log).to eq([ :disposed ])
  end
end
