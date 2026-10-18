require "rails_helper"

RSpec.describe BuildCache::DaemonRestarter do
  let(:env) { { "SCCACHE_SERVER_PORT" => "20042" } }

  describe ".restart!" do
    def stub_capture(success: false, error: nil)
      runner = instance_double(ProcessRunner)
      allow(ProcessRunner).to receive(:new).and_return(runner)
      if error
        allow(runner).to receive(:capture).and_raise(error)
      else
        allow(runner).to receive(:capture).and_return(double(success?: success))
      end
    end

    it "returns true when --stop-server exits successfully" do
      stub_capture(success: true)

      expect(described_class.restart!(env: env)).to eq(true)
    end

    it "returns false when --stop-server exits non-zero" do
      stub_capture

      expect(described_class.restart!(env: env)).to eq(false)
    end

    it "returns false when the sccache binary is not on PATH" do
      stub_capture(error: Errno::ENOENT.new)

      expect(described_class.restart!(env: env)).to eq(false)
    end

    it "returns false and logs a warning when the call times out" do
      stub_capture(error: Timeout::Error.new("execution expired"))
      allow(Rails.logger).to receive(:warn)

      expect(described_class.restart!(env: env)).to eq(false)
      expect(Rails.logger).to have_received(:warn).with(/BuildCache::DaemonRestarter/)
    end
  end
end
