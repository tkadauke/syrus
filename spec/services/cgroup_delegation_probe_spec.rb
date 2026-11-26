require "rails_helper"
require "tmpdir"

RSpec.describe CgroupDelegationProbe do
  around do |example|
    Dir.mktmpdir("syrus-cgroup-probe") do |dir|
      @cgroup = Pathname.new(dir)
      example.run
    end
  end

  def write(file, contents) = @cgroup.join(file).write(contents)

  def probe = described_class.new(cgroup_path: @cgroup.to_s).call

  before do
    write("cgroup.controllers", "cpuset cpu io memory pids\n")
    write("cgroup.subtree_control", "")
    write("cgroup.procs", "")
  end

  it "reports a delegated, empty cgroup as ready" do
    expect(probe).to include("state" => "ready", "available_controllers" => %w[cpuset cpu io memory pids])
  end

  it "reports that the worker's own processes must move into a control child first" do
    write("cgroup.procs", "1\n42\n")

    expect(probe).to include("state" => "needs_control_move", "process_count" => 2)
  end

  it "reports missing controllers" do
    write("cgroup.controllers", "memory pids\n")

    expect(probe).to include("state" => "unavailable", "reason" => a_string_including("cpu, io"))
  end

  it "reports a cgroup it cannot create children in as read-only, and leaves nothing behind" do
    FileUtils.chmod(0o555, @cgroup)

    expect(probe).to include("state" => "read_only")
  ensure
    FileUtils.chmod(0o755, @cgroup)
    expect(Dir.children(@cgroup).grep(/delegation-probe/)).to be_empty
  end

  it "is published with the worker capability diagnostics" do
    allow(described_class).to receive(:capability).and_return("state" => "ready")
    WorkerCapabilities.reset_detection_cache! if WorkerCapabilities.respond_to?(:reset_detection_cache!)

    expect(WorkerCapabilities.current.fetch(:diagnostics)).to include("cgroup_delegation" => { "state" => "ready" })
  end
end
