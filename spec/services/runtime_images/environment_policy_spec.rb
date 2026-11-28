require "rails_helper"

RSpec.describe RuntimeImages::EnvironmentPolicy do
  it "coerces administrator form values to the default value types" do
    policy = described_class.update!(
      "builder" => { "max_concurrent_builds" => "4", "cpus" => "2.5" },
      "revocation" => { "terminate_running_turns_on_severe" => "false" }
    )

    expect(policy.dig("builder", "max_concurrent_builds")).to eq(4)
    expect(policy.dig("builder", "cpus")).to eq(2.5)
    expect(policy.dig("revocation", "terminate_running_turns_on_severe")).to be(false)
  end

  it "rejects unknown sections and settings" do
    expect { described_class.update!("unknown" => {}) }
      .to raise_error(ArgumentError, /unknown policy sections: unknown/)
    expect { described_class.update!("builder" => { "unknown" => 1 }) }
      .to raise_error(ArgumentError, /unknown builder settings: unknown/)
  end

  it "rejects invalid numeric, severity, and ABI values" do
    expect { described_class.update!("builder" => { "pids" => 0 }) }
      .to raise_error(ArgumentError, /builder.pids must be positive/)
    expect { described_class.update!("worker_cache" => { "max_bytes" => -1 }) }
      .to raise_error(ArgumentError, /worker_cache.max_bytes must be non-negative/)
    expect { described_class.update!("supply_chain" => { "blocked_severities" => [ "urgent" ] }) }
      .to raise_error(ArgumentError, /unknown vulnerability severities: urgent/)
    expect { described_class.update!("base_promotion" => { "minimum_abi" => 2, "maximum_abi" => 1 }) }
      .to raise_error(ArgumentError, /minimum ABI must not exceed maximum ABI/)
  end

  it "accepts an empty severity blocklist and equal ABI boundaries" do
    policy = described_class.update!(
      "supply_chain" => { "blocked_severities" => [] },
      "base_promotion" => { "minimum_abi" => 1, "maximum_abi" => 1 }
    )

    expect(policy.dig("supply_chain", "blocked_severities")).to eq([])
    expect(policy.dig("base_promotion", "minimum_abi")).to eq(policy.dig("base_promotion", "maximum_abi"))
  end
end
