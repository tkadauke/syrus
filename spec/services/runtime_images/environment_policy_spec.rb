require "rails_helper"

RSpec.describe RuntimeImages::EnvironmentPolicy do
  it "merges durable administrator overrides over safe defaults" do
    AppSetting.current.update!(runtime_environment_policy: { "builder" => { "max_concurrent_builds" => 7 } })

    expect(described_class.current.fetch("builder", "max_concurrent_builds")).to eq(7)
    expect(described_class.current.fetch("verification", "blocked_severities")).to eq(%w[critical high])
  end

  it "rejects an unknown mount profile" do
    value = described_class::DEFAULTS.deep_merge("runtime" => { "mount_profile" => "host" })
    expect { described_class.new(value) }.to raise_error(described_class::Invalid, /mount_profile/)
  end
end
