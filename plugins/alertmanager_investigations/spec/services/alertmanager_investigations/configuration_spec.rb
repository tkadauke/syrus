require "rails_helper"

RSpec.describe AlertmanagerInvestigations::Configuration do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "infra") }

  it "fails closed without an allowlist" do
    configuration = described_class.new(record: nil)

    expect(configuration.runbook_allowed?(repository, "runbooks/disk.md")).to eq(false)
  end

  it "matches repository slugs and path prefixes on segment boundaries" do
    record = PluginRecord.new(config: {
      "settings" => { "allowed_runbooks" => "acme/infra:runbooks/production\nother/repo:ops" }
    })
    configuration = described_class.new(record: record)

    expect(configuration.runbook_allowed?(repository, "runbooks/production/disk.md")).to eq(true)
    expect(configuration.runbook_allowed?(repository, "runbooks/production-old/disk.md")).to eq(false)
    expect(configuration.runbook_allowed?(repository, "README.md")).to eq(false)
  end
end
