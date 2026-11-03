require "rails_helper"

RSpec.describe RunHostAdmissionCapacity do
  before do
    stub_const("ENV", ENV.to_h.except(
      "SYRUS_AGENTIC_CAPACITY_UNITS", "SYRUS_GRADER_CAPACITY_UNITS", "SYRUS_AGENTIC_RESERVED_UNITS",
      RunProcessParallelism::CPU_LIMIT_ENV
    ))
    allow(RunProcessParallelism).to receive(:cgroup_v2_cpu_count).and_return(nil)
    allow(RunProcessParallelism).to receive(:cgroup_v1_cpu_count).and_return(nil)
    allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(16.gigabytes)
  end

  it "derives capacity from a cgroup CPU quota" do
    allow(RunProcessParallelism).to receive(:cgroup_v2_cpu_count).and_return(8)

    expect(described_class.snapshot).to include(
      "effective_cpu_count" => 8,
      "cpu_source" => "cgroup_v2_quota",
      "cpu_fallback_in_effect" => false,
      "host_compute_capacity" => 6,
      "agentic_capacity_units" => 2,
      "agentic_runs_per_host" => 3,
      "grader_capacity_units" => 1,
      "grader_runs_per_host" => 6,
      "agentic_reserved_units" => 2,
      "memory_limit_bytes" => 16.gigabytes,
      "memory_budget_bytes" => (16.gigabytes * RunHostAdmission::MEMORY_UTILIZATION).floor
    )
  end

  it "flags the undetectable fallback that silently shrinks a worker" do
    allow(Etc).to receive(:nprocessors).and_return(8)

    expect(described_class.snapshot).to include(
      "effective_cpu_count" => RunProcessParallelism::UNDETECTABLE_CPU_COUNT,
      "cpu_source" => "undetectable_fallback",
      "cpu_fallback_in_effect" => true,
      "host_compute_capacity" => 3,
      "agentic_runs_per_host" => 1
    )
  end

  it "honors the capacity-unit env vars the way RunHostAdmission does" do
    allow(RunProcessParallelism).to receive(:cgroup_v2_cpu_count).and_return(10)
    stub_const("ENV", ENV.to_h.merge("SYRUS_AGENTIC_CAPACITY_UNITS" => "4", "SYRUS_AGENTIC_RESERVED_UNITS" => "1"))

    expect(described_class.snapshot).to include(
      "host_compute_capacity" => 8, "agentic_capacity_units" => 4, "agentic_runs_per_host" => 2, "agentic_reserved_units" => 1
    )
  end

  it "is published with the worker capability diagnostics" do
    expect(WorkerCapabilities.current.fetch(:diagnostics)).to include("admission_capacity" => include("host_compute_capacity"))
  end
end
