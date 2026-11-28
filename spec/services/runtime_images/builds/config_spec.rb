require "rails_helper"

RSpec.describe RuntimeImages::Builds::Config do
  it "uses durable administrator overrides ahead of deployment fallbacks" do
    AppSetting.current.update!(runtime_environment_policy: {
      "builder" => { "max_concurrent_builds" => 7, "memory_bytes" => 12_345 }
    })

    expect(described_class.max_concurrent_builds).to eq(7)
    expect(described_class.build_memory_bytes).to eq(12_345)
  end
end
