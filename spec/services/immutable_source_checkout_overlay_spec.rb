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
      allow(File).to receive(:read).and_call_original
      allow(File).to receive(:read).with("/proc/filesystems").and_return("nodev\toverlay\n")
      # Deterministic host facts; individual examples override what they test.
      allow(described_class).to receive_messages(
        read_integer: nil, executable_on_path?: true, cap_sys_admin?: nil
      )
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
      expect(capability.reason).to include("direct mount denied (EPERM: must be superuser to use mount)")
      expect(capability.reason).to include("user-namespace mount denied")
    end

    it "records both attempts' command, exit status and trimmed stderr" do
      allow(described_class).to receive(:capture).and_return(
        capture(success: false, stderr: "direct boom", exit_status: 32),
        capture(success: false, stderr: "x" * 2000, exit_status: 1)
      )

      diagnostics = described_class.probe_capability.diagnostics

      expect(diagnostics.dig("direct", "command")).to start_with("mount -t overlay")
      expect(diagnostics.dig("direct", "exit_status")).to eq(32)
      expect(diagnostics.dig("direct", "stderr")).to eq("direct boom")
      expect(diagnostics.dig("user_namespace", "command")).to start_with("unshare --user")
      expect(diagnostics.dig("user_namespace", "exit_status")).to eq(1)
      expect(diagnostics.dig("user_namespace", "stderr").length).to be <= described_class::STDERR_LIMIT
    end

    context "when the environment explains the failure" do
      before do
        allow(described_class).to receive(:capture).and_return(capture(success: false, stderr: "Operation not permitted"))
      end

      it "names disabled user namespaces" do
        allow(described_class).to receive(:read_integer).with("/proc/sys/user/max_user_namespaces").and_return(0)

        reason = described_class.probe_capability.reason

        expect(reason).to include("direct mount denied (EPERM: Operation not permitted)")
        expect(reason).to include("unprivileged user namespaces disabled (max_user_namespaces=0)")
      end

      it "names kernel.unprivileged_userns_clone" do
        allow(described_class).to receive(:read_integer).with("/proc/sys/user/max_user_namespaces").and_return(1000)
        allow(described_class).to receive(:read_integer).with("/proc/sys/kernel/unprivileged_userns_clone").and_return(0)

        expect(described_class.probe_capability.reason).to include("kernel.unprivileged_userns_clone=0")
      end

      it "names a missing unshare binary" do
        allow(described_class).to receive(:executable_on_path?).with("unshare").and_return(false)

        capability = described_class.probe_capability

        expect(capability.reason).to include("unshare binary missing")
        expect(capability.diagnostics["unshare_available"]).to be(false)
      end

      it "names a missing mount binary" do
        allow(described_class).to receive(:executable_on_path?).with("unshare").and_return(true)
        allow(described_class).to receive(:executable_on_path?).with("mount").and_return(false)

        expect(described_class.probe_capability.reason).to include("mount binary missing")
      end

      it "records environment facts" do
        allow(described_class).to receive(:cap_sys_admin?).and_return(false)

        diagnostics = described_class.probe_capability.diagnostics

        expect(diagnostics).to include("effective_uid" => Process.euid, "cap_sys_admin" => false, "overlay_in_proc_filesystems" => true)
        expect(diagnostics).to have_key("probe_dir_filesystem")
      end
    end

    it "explains an overlay-less kernel" do
      allow(File).to receive(:read).with("/proc/filesystems").and_return("nodev\ttmpfs\n")
      expect(described_class).not_to receive(:capture)

      capability = described_class.probe_capability

      expect(capability.strategy).to eq(:unavailable)
      expect(capability.reason).to include("not listed in /proc/filesystems")
      expect(capability.diagnostics["overlay_in_proc_filesystems"]).to be(false)
    end

    it "reports non-Linux workers without probing" do
      allow(RbConfig::CONFIG).to receive(:fetch).with("host_os").and_return("darwin")
      expect(described_class).not_to receive(:capture)

      expect(described_class.probe_capability.reason).to eq("overlayfs requires Linux workers")
    end
  end

  describe ".cap_sys_admin?" do
    it "reads bit 21 of CapEff" do
      allow(File).to receive(:readlines).with("/proc/self/status").and_return([ "CapEff:\t0000000000200000\n" ])
      expect(described_class.cap_sys_admin?).to be(true)
      allow(File).to receive(:readlines).with("/proc/self/status").and_return([ "CapEff:\t0000000000000000\n" ])
      expect(described_class.cap_sys_admin?).to be(false)
    end
  end

  describe ".filesystem_type" do
    it "uses the longest matching mountpoint" do
      allow(File).to receive(:readlines).with("/proc/self/mountinfo", chomp: true).and_return([
        "1 0 0:1 / / rw - ext4 /dev/sda rw",
        "2 1 0:2 / /data rw - overlay overlay rw"
      ])
      expect(described_class.filesystem_type("/data/x")).to eq("overlay")
      expect(described_class.filesystem_type("/other")).to eq("ext4")
    end
  end

  it "serializes a capability with its diagnostics" do
    capability = described_class::Capability.new(:unavailable, "nope", { "a" => 1 })
    expect(capability.to_h).to eq("strategy" => "unavailable", "reason" => "nope", "diagnostics" => { "a" => 1 })
  end
end
