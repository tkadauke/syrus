require "rails_helper"
require "rbconfig"

RSpec.describe CredentialStore::SshRunner do
  describe ".capture_mounts" do
    it "declares a writable capture workdir outside the application root" do
      mounts = described_class.capture_mounts

      expect(mounts.workdir).not_to eq(Pathname.new(Dir.pwd).expand_path.to_s)
      expect(mounts.workdir).not_to eq(Rails.root.to_s)
      expect(mounts).to be_writable(mounts.workdir)
      expect(mounts.read_write.map(&:host_path)).to contain_exactly(mounts.workdir)
      expect(File.writable?(mounts.workdir)).to be(true)
    end

    it "does not reproduce the read-only application-root capture failure" do
      application_root = Rails.root.to_s
      capture = instance_double(ProcessRunner::CaptureResult)
      result = instance_double(ProcessRunner::Result, timed_out?: false, exit_status: 0)
      allow(capture).to receive_messages(result: result, stdout: "remote out", stderr: "remote err")
      allow(ProcessRunner).to receive(:new) do |**options|
        raise Errno::EACCES, application_root if options.fetch(:mounts).workdir == application_root

        instance_double(ProcessRunner, capture: capture)
      end
      allow(Dir).to receive(:pwd).and_return(application_root)

      expect {
        described_class.call(env: {}, argv: [ "ssh", "example.test" ])
      }.not_to raise_error
      expect(ProcessRunner).to have_received(:new).with(hash_including(
        mounts: satisfy { |mounts| mounts.workdir != application_root && mounts.writable?(mounts.workdir) }
      ))
    end
  end

  it "preserves separate output streams and records the brokered command" do
    result = described_class.call(
      env: {},
      argv: [ RbConfig.ruby, "-e", '$stdout.write("remote out"); $stderr.write("remote err")' ]
    )

    expect(result).to be_success
    expect(result.stdout).to eq("remote out")
    expect(result.stderr).to eq("remote err")
    expect(result.status).to eq(0)
    expect(SpawnedProcess.order(:id).last).to have_attributes(
      kind: "chat_shell_command", outcome: "succeeded", exit_status: 0
    )
  end

  it "bounds TERM-resistant process groups and pipe-reader cleanup" do
    script = <<~'RUBY'
      trap("TERM") {}
      fork do
        trap("TERM") {}
        loop { sleep 1 }
      end
      loop { sleep 1 }
    RUBY
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    result = described_class.call(env: {}, argv: [ RbConfig.ruby, "-e", script ], timeout: 0.05)

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at
    expect(result.status).to eq(124)
    expect(elapsed).to be < 2
  end
end
