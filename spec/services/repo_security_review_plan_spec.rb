require "rails_helper"

RSpec.describe RepoSecurityReviewPlan do
  it "uses repository configuration" do
    loaded = RepoDefaultBranchSyrusYml::Result.new(
      config: SyrusYml.new("security_review:\n  rounds: 2\n  criteria: [authorization]\n").parse,
      source: ".syrus.yml", note: nil
    )

    plan = described_class.from_syrus_yml(loaded)
    expect(plan.rounds).to eq(2)
    expect(plan.criteria).to eq([ "authorization" ])
  end
end
