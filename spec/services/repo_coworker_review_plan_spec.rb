require "rails_helper"

RSpec.describe RepoCoworkerReviewPlan do
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
end
