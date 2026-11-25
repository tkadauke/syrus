require "rails_helper"

# SpawnedProcessCgroup.unenforceable_reason answers before anything is spawned
# whether a per-spawn cgroup could be set up (F135). The Linux-only behaviour
# is covered in spawned_process_cgroup_spec.rb; these paths hold everywhere.
RSpec.describe SpawnedProcessCgroup, ".unenforceable_reason" do
  it "names the disabled feature flag" do
    allow(Feature).to receive(:per_spawn_resource_limits_enabled?).and_return(false)

    expect(described_class.unenforceable_reason(pids: true)).to eq("per_spawn_resource_limits feature flag is disabled")
  end

  it "names the platform when there is no cgroup v2 to use" do
    allow(Feature).to receive(:per_spawn_resource_limits_enabled?).and_return(true)
    allow(Etc).to receive(:uname).and_return(sysname: "Darwin")

    expect(described_class.unenforceable_reason(pids: true)).to include("Darwin")
  end

  it "creates no cgroup while answering" do
    allow(Feature).to receive(:per_spawn_resource_limits_enabled?).and_return(false)
    expect(described_class).not_to receive(:new)

    described_class.unenforceable_reason
  end
end
