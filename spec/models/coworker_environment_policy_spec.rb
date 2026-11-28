require "rails_helper"

RSpec.describe CoworkerEnvironmentPolicy do
  it "drives builder and verification defaults from the administrator policy" do
    AppSetting.current.update!(coworker_environment_policy: described_class.current.deep_merge(
      "builder" => { "max_concurrent_builds" => 7 },
      "verification" => { "blocked_severities" => [ "critical" ], "prohibited_packages" => [ "nc" ] }
    ))

    expect(RuntimeImages::Builds::Config.max_concurrent_builds).to eq(7)
    expect(RuntimeImages::Verifications::Policy.current).to include(
      "vulnerabilities" => { "blocked_severities" => [ "critical" ] },
      "prohibited_packages" => [ "nc" ]
    )
  end

  describe ".validate!" do
    it "normalizes numeric and boolean values" do
      policy = described_class.validate!(described_class.current.deep_merge(
        "builder" => { "max_attempts" => "4" },
        "cache" => { "max_bytes" => "1024", "prefetch_active" => "true" }
      ))

      expect(policy.dig("builder", "max_attempts")).to eq(4)
      expect(policy.dig("cache", "max_bytes")).to eq(1024)
      expect(policy.dig("cache", "prefetch_active")).to be(true)
    end

    invalid_values = {
      "revocation response" => [ { "revocation" => { "severe_running_turns" => "ignore" } }, /revocation response/ ],
      "cache limit" => [ { "cache" => { "max_bytes" => 0 } }, /cache.max_bytes/ ],
      "scratch profile" => [ { "scratch" => { "profile" => "host_mount" } }, /scratch profile/ ],
      "scratch size" => [ { "scratch" => { "size" => "1g,mode=777" } }, /scratch size/ ],
      "empty severities" => [ { "verification" => { "blocked_severities" => [] } }, /blocked severities/ ],
      "unknown severity" => [ { "verification" => { "blocked_severities" => [ "urgent" ] } }, /blocked severities/ ]
    }

    invalid_values.each do |label, (override, message)|
      it "rejects an invalid #{label}" do
        expect { described_class.validate!(described_class.current.deep_merge(override)) }
          .to raise_error(ArgumentError, message)
      end
    end
  end
end
