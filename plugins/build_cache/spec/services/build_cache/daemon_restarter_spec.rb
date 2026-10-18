require "rails_helper"

RSpec.describe BuildCache::DaemonRestarter do
  let(:env) { { "SCCACHE_SERVER_PORT" => "20042", "PATH" => ENV.fetch("PATH") } }

  describe ".restart!" do
    def stub_capture(success: false, error: nil)
      runner = instance_double(ProcessRunner)
      allow(ProcessRunner).to receive(:new).and_return(runner)
      if error
        allow(runner).to receive(:capture).and_raise(error)
      else
        allow(runner).to receive(:capture).and_return(
          double(success?: success, result: double(timed_out?: false))
        )
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
      stub_const("BuildCache::DaemonRestarter::TIMEOUT_SECONDS", 0.05)
      allow(Rails.logger).to receive(:warn).and_call_original

      Dir.mktmpdir do |dir|
        executable = File.join(dir, "sccache")
        File.write(executable, "#!/bin/sh\nsleep 30\n")
        FileUtils.chmod(0o755, executable)

        expect(described_class.restart!(env: env.merge("PATH" => "#{dir}:#{env.fetch("PATH")}"))).to eq(false)
      end
      expect(Rails.logger).to have_received(:warn).with(/BuildCache::DaemonRestarter/)
      expect(SpawnedProcess.order(:id).last).to have_attributes(kind: "runtime_probe", outcome: "timed_out")
    end
  end
end
