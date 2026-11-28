require "rails_helper"

RSpec.describe RuntimeImages::Verifications::Policy do
  around do |example|
    previous = ENV[described_class::ENV_KEY]
    example.run
  ensure
    ENV[described_class::ENV_KEY] = previous
  end

  it "keeps strict required checks while applying instance policy" do
    ENV[described_class::ENV_KEY] = JSON.generate(
      "checks" => [], "vulnerabilities" => { "blocked_severities" => [ "critical" ] },
      "prohibited_packages" => [ "telnet" ]
    )

    policy = described_class.current

    expect(policy["checks"]).to eq(RuntimeImages::Verifications::Orchestrator::DEFAULT_POLICY["checks"])
    expect(policy.dig("vulnerabilities", "blocked_severities")).to eq([ "critical" ])
    expect(policy["prohibited_packages"]).to eq([ "telnet" ])
  end

  it "applies durable administrator policy over the deployment fallback" do
    ENV[described_class::ENV_KEY] = JSON.generate(
      "vulnerabilities" => { "blocked_severities" => [ "critical" ] },
      "prohibited_packages" => [ "telnet" ]
    )
    AppSetting.current.update!(runtime_environment_policy: {
      "verification" => { "blocked_severities" => [ "critical", "high" ], "prohibited_packages" => [ "openssl-legacy" ] }
    })

    policy = described_class.current

    expect(policy.dig("vulnerabilities", "blocked_severities")).to eq(%w[critical high])
    expect(policy["prohibited_packages"]).to eq([ "openssl-legacy" ])
  end

  it "fails closed on invalid configuration" do
    ENV[described_class::ENV_KEY] = "not-json"

    expect { described_class.current }.to raise_error(RuntimeImages::ProviderError, /invalid JSON/)
  end
end
