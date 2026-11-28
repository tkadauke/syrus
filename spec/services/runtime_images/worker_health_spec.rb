require "rails_helper"

RSpec.describe RuntimeImages::WorkerHealth do
  it "reports registry, cache-integrity, ABI, and termination readiness without credentials" do
    configuration = instance_double(RuntimeImages::OciRegistry::Configuration, credential?: true)
    allow(RuntimeImages::OciRegistry::Configuration).to receive(:from_env).and_return(configuration)
    RuntimeImagePullEvent.create!(hostname: "worker-a", digest: "sha256:#{'a' * 64}", outcome: "corrupt")

    snapshot = described_class.snapshot(hostname: "worker-a")

    expect(snapshot).to include(
      "registry_access" => "configured_unverified",
      "cache_integrity" => "failed",
      "cache_integrity_failures_24h" => 1,
      "base_abi_compatible" => true,
      "termination_support" => true
    )
    expect(snapshot.to_s).not_to include("password", "secret")
  end
end
