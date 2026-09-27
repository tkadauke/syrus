require "rails_helper"
require "tmpdir"

RSpec.describe ImmutableSourceCheckoutOverlay, :ci_only do
  around do |example|
    Dir.mktmpdir("syrus-overlay") do |dir|
      @root = Pathname.new(dir)
      example.run
    end
  end

  it "mounts overlayfs when Linux support is present" do
    lower = @root.join("lower")
    mount = @root.join("mount")
    FileUtils.mkdir_p(lower)
    allow(RbConfig::CONFIG).to receive(:fetch).with("host_os").and_return("linux-gnu")
    allow(File).to receive(:read).with("/proc/filesystems").and_return("nodev\toverlay\n")
    allow(Open3).to receive(:capture3)
      .with("mount", "-t", "overlay", "overlay", "-o", /lowerdir=#{Regexp.escape(lower.to_s)}/, mount.to_s)
      .and_return([ "", "", instance_double(Process::Status, success?: true) ])

    result = described_class.mount(lower_path: lower, mount_path: mount)

    expect(result).to be_mounted
    expect(result.strategy).to eq("overlay")
    expect(result.lower_path).to eq(lower.to_s)
    expect(result.mount_path).to eq(mount.to_s)
    expect(mount).to be_directory
  end

  it "returns a copy fallback reason before attempting mount on non-Linux workers" do
    lower = @root.join("lower")
    mount = @root.join("mount")
    FileUtils.mkdir_p(lower)
    allow(RbConfig::CONFIG).to receive(:fetch).with("host_os").and_return("darwin")
    allow(Open3).to receive(:capture3)

    result = described_class.mount(lower_path: lower, mount_path: mount)

    expect(result).not_to be_mounted
    expect(result.strategy).to eq("copy")
    expect(result.reason).to eq("overlayfs requires Linux workers")
    expect(Open3).not_to have_received(:capture3)
  end

  it "returns the mount failure as the explicit fallback reason" do
    lower = @root.join("lower")
    mount = @root.join("mount")
    FileUtils.mkdir_p(lower)
    allow(RbConfig::CONFIG).to receive(:fetch).with("host_os").and_return("linux-gnu")
    allow(File).to receive(:read).with("/proc/filesystems").and_return("nodev\toverlay\n")
    allow(Open3).to receive(:capture3).and_return([ "", "wrong fs type", instance_double(Process::Status, success?: false, exitstatus: 32) ])

    result = described_class.mount(lower_path: lower, mount_path: mount)

    expect(result).not_to be_mounted
    expect(result.strategy).to eq("copy")
    expect(result.reason).to eq("overlay mount failed: wrong fs type")
  end
end
