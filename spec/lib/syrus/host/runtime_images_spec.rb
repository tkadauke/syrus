require "rails_helper"

RSpec.describe Syrus::Host::RuntimeImages do
  it "exposes saved runtime environment policy overrides to plugins" do
    AppSetting.current.update!(runtime_environment_policy: {
      "runtime" => { "mount_profile" => "executable_scratch", "scratch_size" => "2g" }
    })

    expect(described_class.environment_policy_override("runtime", "mount_profile")).to eq("executable_scratch")
    expect(described_class.environment_policy_override("runtime", "scratch_size")).to eq("2g")
  end
end
