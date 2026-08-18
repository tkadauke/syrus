require "rails_helper"

RSpec.describe RestartWatcher do
  after { described_class.reset_for_tests! }

  describe ".tick" do
    it "kills the process when the cache holds a timestamp newer than started_at" do
      described_class.started_at
      allow(Rails.cache).to receive(:read).with("syrus:restart_local").and_return(described_class.started_at + 1)
      allow(described_class).to receive(:sleep)
      allow(Process).to receive(:kill)

      expect(described_class.tick).to be(true)

      expect(Process).to have_received(:kill).with("TERM", Process.pid)
    end

    it "does not kill the process when the cache is nil" do
      described_class.started_at
      allow(Rails.cache).to receive(:read).with("syrus:restart_local").and_return(nil)
      expect(Process).not_to receive(:kill)

      expect(described_class.tick).to be(false)
    end

    it "does not kill the process when the cached timestamp predates started_at" do
      described_class.started_at
      allow(Rails.cache).to receive(:read).with("syrus:restart_local").and_return(described_class.started_at - 10)
      expect(Process).not_to receive(:kill)

      expect(described_class.tick).to be(false)
    end

    it "logs a warning and does not raise when Rails.cache.read fails" do
      allow(Rails.cache).to receive(:read).and_raise(StandardError, "cache unavailable")
      expect(Process).not_to receive(:kill)
      expect(Rails.logger).to receive(:warn).with(/cache unavailable/)

      expect { described_class.tick }.not_to raise_error
    end

    it "scopes the cache key to the current role" do
      allow(SyrusVersion).to receive(:role).and_return("worker")
      expect(Rails.cache).to receive(:read).with("syrus:restart_worker").and_return(nil)

      described_class.tick
    end
  end

  describe ".ensure_running" do
    it "is a no-op in the test environment" do
      expect { described_class.ensure_running }.not_to raise_error
    end
  end
end
