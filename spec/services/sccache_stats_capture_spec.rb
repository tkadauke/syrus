require "rails_helper"

RSpec.describe SccacheStatsCapture do
  let(:env) { { "PATH" => ENV["PATH"] } }
  let(:chdir) { Dir.tmpdir }

  describe ".capture" do
    it "returns nil when the sccache binary is not on PATH" do
      # Some worker images ship `sccache` (EPIC-251's shared compiler cache),
      # so this can't rely on the sandbox lacking the binary. Stub the
      # Errno::ENOENT a non-C/C++ repo (or an image built before sccache
      # existed) hits on every call instead.
      allow(Open3).to receive(:capture2e).and_raise(Errno::ENOENT)

      expect(described_class.capture(env: env, chdir: chdir)).to be_nil
    end

    it "returns the parsed stats hash on a clean JSON success" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e)
        .with(env, "sccache", "--show-stats", "--stats-format=json", chdir: chdir.to_s)
        .and_return([ '{"compile_requests": 12}', status ])

      expect(described_class.capture(env: env, chdir: chdir)).to eq({ "compile_requests" => 12 })
    end

    it "returns nil when sccache exits non-zero" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture2e).and_return([ "sccache: error: server startup failed", status ])

      expect(described_class.capture(env: env, chdir: chdir)).to be_nil
    end

    it "returns nil and logs a warning on unparseable output" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture2e).and_return([ "not json", status ])
      allow(Rails.logger).to receive(:warn)

      expect(described_class.capture(env: env, chdir: chdir)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/SccacheStatsCapture.*JSON/)
    end

    it "returns nil and logs a warning when the call times out" do
      allow(Open3).to receive(:capture2e).and_raise(Timeout::Error, "execution expired")
      allow(Rails.logger).to receive(:warn)

      expect(described_class.capture(env: env, chdir: chdir)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/SccacheStatsCapture/)
    end
  end
end
