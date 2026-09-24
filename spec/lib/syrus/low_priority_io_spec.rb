require "rails_helper"

RSpec.describe Syrus::LowPriorityIo do
  # Both sides: the PATH lookup is memoized on the module, so whichever spec
  # called `wrap` first in a full suite run has already frozen availability
  # and the stub below would never be consulted.
  before { described_class.reset_memoization_for_test! }
  after { described_class.reset_memoization_for_test! }

  describe ".wrap" do
    it "prefixes the command with ionice and nice when both are on PATH" do
      # The host cannot be the fixture here: `ionice` is util-linux, so a
      # macOS dev machine has `nice` and not `ionice` and saw only half the
      # prefix. Stub the lookup so the example asserts wrap's own behavior
      # rather than which kernel the suite happens to run on.
      allow(File).to receive(:executable?).and_return(true)

      expect(described_class.wrap([ "du", "-sk", "/tmp/x" ]))
        .to eq(%w[ionice -c3 nice -n 19 du -sk /tmp/x])
    end

    it "falls back to the bare command when neither binary is available" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PATH").and_return("/nonexistent/bin")

      expect(described_class.wrap([ "rm", "-rf", "/tmp/x" ])).to eq(%w[rm -rf /tmp/x])
    end

    it "memoizes the PATH lookup across calls" do
      described_class.wrap([ "du" ])
      expect(File).not_to receive(:executable?)

      described_class.wrap([ "du" ])
    end
  end
end
