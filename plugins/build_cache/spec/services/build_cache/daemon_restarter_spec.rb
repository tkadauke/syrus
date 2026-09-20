require "rails_helper"

RSpec.describe BuildCache::DaemonRestarter do
  let(:env) { { "SCCACHE_SERVER_PORT" => "20042" } }

  describe ".restart!" do
    it "returns true when --stop-server exits successfully" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e)
        .with(env, "sccache", "--stop-server")
        .and_return([ "Stopped the server", status ])

      expect(described_class.restart!(env: env)).to eq(true)
    end

    it "returns false when --stop-server exits non-zero" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture2e).and_return([ "sccache: no server running", status ])

      expect(described_class.restart!(env: env)).to eq(false)
    end

    it "returns false when the sccache binary is not on PATH" do
      allow(Open3).to receive(:capture2e).and_raise(Errno::ENOENT)

      expect(described_class.restart!(env: env)).to eq(false)
    end

    it "returns false and logs a warning when the call times out" do
      allow(Open3).to receive(:capture2e).and_raise(Timeout::Error, "execution expired")
      allow(Rails.logger).to receive(:warn)

      expect(described_class.restart!(env: env)).to eq(false)
      expect(Rails.logger).to have_received(:warn).with(/BuildCache::DaemonRestarter/)
    end
  end
end
