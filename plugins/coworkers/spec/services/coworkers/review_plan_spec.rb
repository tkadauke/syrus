require "rails_helper"

RSpec.describe Coworkers::ReviewPlan do
  around do |example|
    plugin_record = PluginRecord.find_by!(name: "coworkers")
    originally_enabled = plugin_record.enabled?
    plugin_record.update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
    example.run
  ensure
    plugin_record&.update!(enabled: originally_enabled)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  def loaded(yaml)
    RepoDefaultBranchSyrusYml::Result.new(
      config: SyrusYml.new(yaml).parse,
      source: ".syrus.yml",
      note: nil
    )
  end

  it "enables only an explicitly enabled configuration" do
    result = described_class.from_syrus_yml(loaded(<<~YAML))
      coworker_review:
        enabled: true
        rounds: 2
        required: true
        criteria: [Check rollout ownership]
    YAML

    expect(result).to have_attributes(
      enabled?: true, rounds: 2, required: true, criteria: [ "Check rollout ownership" ]
    )
  end

  it "does not enable a present mapping without enabled true" do
    result = described_class.from_syrus_yml(loaded("coworker_review:\n  rounds: 2\n"))

    expect(result.enabled?).to be(false)
  end

  it "does not enable an absent mapping" do
    result = described_class.from_syrus_yml(loaded("prepare: false\n"))

    expect(result).to have_attributes(enabled?: false, rounds: 0, note: "no coworker_review configured")
  end

  it "does not enable the legacy mapping when the provider is unavailable" do
    allow(Syrus::PluginRegistry).to receive(:health).and_return(double(healthy?: false))

    result = described_class.from_syrus_yml(loaded(<<~YAML))
      coworker_review:
        enabled: true
        rounds: 2
    YAML

    expect(result).to have_attributes(
      enabled?: false, rounds: 0, note: "no coworker_review configured"
    )
  end
end
