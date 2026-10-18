require "rails_helper"
require "tmpdir"

RSpec.describe ImmutableSourceCheckoutOverlay, :ci_only do
  around do |example|
    Dir.mktmpdir("syrus-overlay") do |dir|
      @root = Pathname.new(dir)
      example.run
    end
  end

  let(:lower) { @root.join("lower").tap { |path| FileUtils.mkdir_p(path) } }
  let(:mount) { @root.join("mount") }

  def capture(success:, stdout: "", stderr: "", exit_status: success ? 0 : 32)
    result = ProcessRunner::Result.new(
      exit_status: exit_status, timed_out: false, stopped: false, silent_timed_out: false,
      operator_killed: false, aliveness_failed: false, duration_s: 0.1, spawned_process_id: nil
    )
    ProcessRunner::CaptureResult.new(
      result: result, stdout: stdout, stderr: stderr,
      stdout_truncated: false, stderr_truncated: false
    )
  end

  it "mounts overlayfs when the worker can mount it directly" do
    allow(described_class).to receive(:capability).and_return(described_class::Capability.new(:direct, nil))
    expect(described_class).to receive(:capture)
      .with(array_including("mount", /lowerdir=#{Regexp.escape(lower.to_s)}/), workdir: mount.dirname)
      .and_return(capture(success: true))

    result = described_class.mount(lower_path: lower, mount_path: mount)

    expect(result).to be_mounted
    expect(result.strategy).to eq("overlay")
    expect(result.lower_path).to eq(lower.to_s)
    expect(result.mount_path).to eq(mount.to_s)
    expect(mount).to be_directory
  end

  # The probe runs once per process, so a worker that cannot mount stops paying
  # for the attempt: production logged 2,232 failed mounts in one day before
  # this, each followed by the same fallback.
  it "does not attempt a mount on a worker that cannot do one" do
    allow(described_class).to receive(:capability)
      .and_return(described_class::Capability.new(:unavailable, "overlay mount failed: must be superuser to use mount"))
    expect(described_class).not_to receive(:capture)

    result = described_class.mount(lower_path: lower, mount_path: mount)

    expect(result).not_to be_mounted
    expect(result.strategy).to eq("copy")
    expect(result.reason).to eq("overlay mount failed: must be superuser to use mount")
  end

  it "returns the mount failure as the explicit fallback reason" do
    allow(described_class).to receive(:capability).and_return(described_class::Capability.new(:direct, nil))
    allow(described_class).to receive(:capture).and_return(capture(success: false, stderr: "wrong fs type"))

    result = described_class.mount(lower_path: lower, mount_path: mount)

    expect(result).not_to be_mounted
    expect(result.strategy).to eq("copy")
    expect(result.reason).to eq("overlay mount failed: wrong fs type")
  end

  describe ".probe_capability" do
    before do
      allow(RbConfig::CONFIG).to receive(:fetch).with("host_os").and_return("linux-gnu")
      allow(File).to receive(:read).with("/proc/filesystems").and_return("nodev\toverlay\n")
    end

    it "reports a direct mount when the worker holds the capability" do
      allow(described_class).to receive(:capture).and_return(capture(success: true))
      allow(described_class).to receive(:unmount)

      capability = described_class.probe_capability

      expect(capability).to be_direct
      expect(capability).to be_available
    end

    # Kernels 5.11+ allow an unprivileged overlayfs mount inside a user
    # namespace, which is what a stock Kubernetes worker can actually do. The
    # strategy is recorded rather than used: the mount lives in the namespace,
    # so the graded command would have to run inside it too.
    it "reports a user-namespace mount when only the unprivileged path works" do
      allow(described_class).to receive(:capture).and_return(
        capture(success: false, stderr: "must be superuser to use mount"),
        capture(success: true)
      )

      capability = described_class.probe_capability

      expect(capability).to be_user_namespace
      expect(capability).not_to be_available
      expect(capability.reason).to include("must be superuser")
    end

    it "reports neither when both paths are refused" do
      allow(described_class).to receive(:capture)
        .and_return(capture(success: false, stderr: "must be superuser to use mount"))

      capability = described_class.probe_capability

      expect(capability.strategy).to eq(:unavailable)
      expect(capability.reason).to include("must be superuser")
    end

    it "reports non-Linux workers without probing" do
      allow(RbConfig::CONFIG).to receive(:fetch).with("host_os").and_return("darwin")
      expect(described_class).not_to receive(:capture)

      expect(described_class.probe_capability.reason).to eq("overlayfs requires Linux workers")
    end
  end
end
