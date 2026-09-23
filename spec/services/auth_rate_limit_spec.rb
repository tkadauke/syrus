require "rails_helper"

RSpec.describe AuthRateLimit do
  around do |example|
    original = ENV[described_class::DISABLE_ENV_VAR]
    example.run
  ensure
    original.nil? ? ENV.delete(described_class::DISABLE_ENV_VAR) : ENV[described_class::DISABLE_ENV_VAR] = original
  end

  it "is on by default" do
    ENV.delete(described_class::DISABLE_ENV_VAR)

    expect(described_class).to be_enabled
  end

  it "is lifted for the E2E harness" do
    ENV[described_class::DISABLE_ENV_VAR] = "1"

    expect(described_class).not_to be_enabled
  end

  it "only accepts an exact opt-out" do
    [ "0", "true", "yes", "" ].each do |value|
      ENV[described_class::DISABLE_ENV_VAR] = value

      expect(described_class).to be_enabled, "expected #{value.inspect} to leave the limit on"
    end
  end

  # A brute-force defense an environment variable can switch off is not a
  # defense, and the harness never runs there.
  it "ignores the variable in production" do
    allow(Rails).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
    ENV[described_class::DISABLE_ENV_VAR] = "1"

    expect(described_class).to be_enabled
  end
end
