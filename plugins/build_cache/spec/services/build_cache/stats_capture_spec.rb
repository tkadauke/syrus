require "rails_helper"

RSpec.describe BuildCache::StatsCapture do
  let(:env) { { "PATH" => ENV["PATH"] } }
  let(:chdir) { Dir.tmpdir }

  describe ".capture" do
    def stub_capture(stdout: "", success: false, error: nil)
      runner = instance_double(ProcessRunner)
      allow(ProcessRunner).to receive(:new).and_return(runner)
      value = double(success?: success, stdout: stdout)
      if error
        allow(runner).to receive(:capture).and_raise(error)
      else
        allow(runner).to receive(:capture).and_return(value)
      end
    end

    it "returns nil when the sccache binary is not on PATH" do
      # Stubbed rather than relying on ambient PATH: some sandboxes (this one
      # included) do have a real `sccache` binary installed, which would
      # otherwise make this exercise the success path instead of the
      # Errno::ENOENT a non-C/C++ repo (or an image built before sccache
      # existed) hits on every call.
      stub_capture(error: Errno::ENOENT.new)

      expect(described_class.capture(env: env, chdir: chdir)).to be_nil
    end

    it "returns the parsed stats hash on a clean JSON success" do
      stub_capture(stdout: '{"compile_requests": 12}', success: true)

      expect(described_class.capture(env: env, chdir: chdir)).to eq({ "compile_requests" => 12 })
    end

    it "returns nil when sccache exits non-zero" do
      stub_capture(stdout: "sccache: error: server startup failed")

      expect(described_class.capture(env: env, chdir: chdir)).to be_nil
    end

    it "returns nil and logs a warning on unparseable output" do
      stub_capture(stdout: "not json", success: true)
      allow(Rails.logger).to receive(:warn)

      expect(described_class.capture(env: env, chdir: chdir)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/BuildCache::StatsCapture.*JSON/)
    end

    it "returns nil and logs a warning when the call times out" do
      stub_capture(error: Timeout::Error.new("execution expired"))
      allow(Rails.logger).to receive(:warn)

      expect(described_class.capture(env: env, chdir: chdir)).to be_nil
      expect(Rails.logger).to have_received(:warn).with(/BuildCache::StatsCapture/)
    end
  end
end
