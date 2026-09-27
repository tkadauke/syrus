require "rails_helper"
require "tmpdir"

RSpec.describe SpawnedProcessCgroup, :ci_only do
  around do |example|
    @previous_env = ENV.to_h
    @cgroup_parent = Dir.mktmpdir("spawned-process-cgroup")
    ENV["SYRUS_SPAWN_CGROUP_PARENT"] = @cgroup_parent
    ENV["SYRUS_SPAWN_MEMORY_MAX_BYTES"] = "268435456"
    ENV["SYRUS_SPAWN_MEMORY_HIGH_BYTES"] = "201326592"
    ENV["SYRUS_SPAWN_MEMORY_SWAP_MAX_BYTES"] = "0"
    File.write(File.join(@cgroup_parent, "cgroup.controllers"), "memory cpu io\n")
    Feature.find_or_create_by!(slug: "per_spawn_resource_limits") do |feature|
      feature.category = "Operations"
      feature.name = "Per-spawn resource limits"
    end.update!(enabled: true)
    Feature.clear_enabled_cache!("per_spawn_resource_limits")

    example.run
  ensure
    ENV.replace(@previous_env) if @previous_env
    FileUtils.rm_rf(@cgroup_parent) if @cgroup_parent
    Feature.find_by(slug: "per_spawn_resource_limits")&.update!(enabled: false)
    Feature.clear_enabled_cache!("per_spawn_resource_limits")
  end

  it "records cgroup v2 limit settings, exit counters, oom events, and cleanup state" do
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "agent",
      hostname: "worker-a",
      started_at: Time.current
    )

    cgroup = described_class.new(spawned_process: process)
    cgroup_dir = Dir.glob(File.join(@cgroup_parent, "syrus-spawned-process-*")).sole
    File.write(File.join(cgroup_dir, "memory.events"), "low 1\nhigh 2\noom 1\noom_kill 1\n")
    File.write(File.join(cgroup_dir, "memory.peak"), "123456\n")
    File.write(File.join(cgroup_dir, "cpu.stat"), "usage_usec 99\nuser_usec 70\nsystem_usec 29\n")
    File.write(File.join(cgroup_dir, "io.stat"), "8:0 rbytes=10 wbytes=20 rios=1 wios=2\n")

    cgroup.attach!(123)
    cgroup.sample_exit!
    cgroup.cleanup!

    expect(cgroup).to be_oom_kill
    expect(cgroup.payload).to include(
      "state" => "applied",
      "memory_max_bytes" => 268_435_456,
      "memory_high_bytes" => 201_326_592,
      "memory_swap_max_bytes" => 0,
      "memory_events" => include("oom_kill" => 1),
      "memory_peak_bytes" => 123_456,
      "cpu_stat" => include("usage_usec" => 99),
      "io_stat" => include("8:0" => include("rbytes" => 10, "wbytes" => 20)),
      "cleanup" => "removed"
    )
    expect(Dir.exist?(cgroup_dir)).to be(false)
  end

  it "derives an adaptive memory ceiling from the effective pod limit, reserves, admission units, and slots" do
    ENV.delete("SYRUS_SPAWN_MEMORY_MAX_BYTES")
    ENV.delete("SYRUS_SPAWN_MEMORY_HIGH_BYTES")
    ENV["JOB_CONCURRENCY"] = "4"
    ENV["SYRUS_AGENTIC_CAPACITY_UNITS"] = "2"
    ENV["SYRUS_SPAWN_RAILS_RESERVED_BYTES"] = "1073741824"
    ENV["SYRUS_SPAWN_FILESYSTEM_RESERVED_BYTES"] = "536870912"
    allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(16.gigabytes)
    allow(RunProcessParallelism).to receive(:host_capacity).and_return(8)
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "agent",
      hostname: "worker-a",
      started_at: Time.current
    )

    cgroup = described_class.new(spawned_process: process)

    expect(cgroup.payload).to include(
      "state" => "ready",
      "memory_max_bytes" => 7_784_628_224,
      "memory_high_bytes" => 7_006_165_401,
      "budget" => include(
        "source" => "adaptive",
        "run_type" => "agentic",
        "admission_units" => 2,
        "concurrent_slots" => 4,
        "effective_memory_limit_bytes" => 17_179_869_184,
        "rails_reserved_bytes" => 1_073_741_824,
        "filesystem_reserved_bytes" => 536_870_912,
        "reservable_memory_bytes" => 15_569_256_448
      )
    )
  end

  it "records unavailable when the worker cgroup is not delegated for child cgroup creation" do
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "agent",
      hostname: "worker-a",
      started_at: Time.current
    )
    allow_any_instance_of(described_class).to receive(:cgroup_delegation_available?).and_return(false)

    cgroup = described_class.new(spawned_process: process)

    expect(cgroup.payload).to include(
      "state" => "unavailable",
      "reason" => "worker cgroup is not delegated for child cgroup creation"
    )
  end

  it "records macOS bare-metal execution as a loud no-enforcement mode" do
    process = SpawnedProcess.create!(
      kind: "agent",
      command: "agent",
      hostname: "worker-a",
      started_at: Time.current
    )
    allow(Etc).to receive(:uname).and_return({ sysname: "Darwin" })

    cgroup = described_class.new(spawned_process: process)

    expect(cgroup.payload).to include(
      "state" => "unavailable",
      "reason" => "no cgroup enforcement available on Darwin outside a Linux container"
    )
  end
end
