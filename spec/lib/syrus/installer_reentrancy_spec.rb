require "rails_helper"

# Every scoped effect used to fail to install with
# `ThreadError: deadlock; recursive locking`, rescued per-registration -- so
# sync! recorded the fingerprint as applied while nothing had actually been
# installed. Two causes, both about re-entrancy: apply! held a non-reentrant
# lock, and it iterated the registration hash an install could add to.
RSpec.describe Syrus::Installer do
  around do |example|
    snapshot = described_class.snapshot
    example.run
    described_class.restore(snapshot)
    described_class.sync!
  end

  it "installs an effect whose block re-enters the installer" do
    installed = []

    described_class.define("reentrancy_probe") do |scope|
      scope.effect("touches the installer") do
        # What a lazily-constructed KindRegistry does during an install.
        described_class.define("reentrancy_probe_nested") { |_| }
        installed << :ran
        -> { }
      end
    end

    described_class.reset!
    described_class.sync!

    expect(installed).to eq([ :ran ])
  end

  it "picks up a registration defined during an install on the next sync" do
    described_class.define("reentrancy_outer") do |scope|
      scope.effect("defines another") do
        described_class.define("reentrancy_inner") { |_| }
        -> { }
      end
    end

    described_class.reset!
    described_class.sync!

    expect(described_class.defined_labels).to include("reentrancy_inner")
  end

  # The symptom that made this invisible: a failed install still marked the
  # fingerprint applied, so nothing retried.
  it "actually installs the bundled scoped effects" do
    described_class.reset!
    described_class.sync!

    expect(ChatSessionRehydrator.for("claude")).to eq(ChatSessionRehydrator::Claude)
  end
end
