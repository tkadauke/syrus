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
end
