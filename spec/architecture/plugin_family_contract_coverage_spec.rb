require "rails_helper"
require "syrus/plugin/family_contract_kit"

RSpec.describe "Bundled plugin family contract coverage" do
  it "runs each bundled family declaration through its generated shared examples" do
    missing = Syrus::Plugin::FamilyContractCoverage.missing

    expect(missing).to be_empty,
      "Bundled family declarations must use their generated shared examples: " \
      "#{missing.map { |entry| "#{entry.plugin}: #{entry.family}/#{entry.provider}" }.join('; ')}"
  end
end
