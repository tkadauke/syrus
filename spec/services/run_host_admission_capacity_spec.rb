require "rails_helper"

RSpec.describe RunHostAdmissionCapacity do
  before do
    stub_const("ENV", ENV.to_h.except(RunProcessParallelism::CPU_LIMIT_ENV))
    allow(RunProcessParallelism).to receive(:cgroup_v2_cpu_count).and_return(nil)
    allow(RunProcessParallelism).to receive(:cgroup_v1_cpu_count).and_return(nil)
    allow(RunProcessParallelism).to receive(:effective_memory_limit_bytes).and_return(16.gigabytes)
  end

  it "publishes the worker's real CPU count, not a discounted share of it" do
    allow(RunProcessParallelism).to receive(:cgroup_v2_cpu_count).and_return(8)

    expect(described_class.snapshot).to eq(
      "effective_cpu_count" => 8,
      "cpu_source" => "cgroup_v2_quota",
      "cpu_fallback_in_effect" => false,
      "host_compute_capacity" => 8,
      "memory_limit_bytes" => 16.gigabytes
    )
  end

  it "flags the undetectable fallback that silently shrinks a worker" do
    allow(Etc).to receive(:nprocessors).and_return(8)

    expect(described_class.snapshot).to include(
      "effective_cpu_count" => RunProcessParallelism::UNDETECTABLE_CPU_COUNT,
      "cpu_source" => "undetectable_fallback",
      "cpu_fallback_in_effect" => true
    )
  end

  it "is published with the worker capability diagnostics" do
    expect(WorkerCapabilities.current.fetch(:diagnostics)).to include("admission_capacity" => include("host_compute_capacity"))
  end
end
