require "rails_helper"

RSpec.describe BranchPublicationPruneJob do
  it "deletes only publications older than the retention window" do
    old = BranchPublication.create!(branch_name: "syrus/a", sha: "a" * 40, created_at: (BranchPublication::RETAIN_FOR + 1.day).ago)
    fresh = BranchPublication.create!(branch_name: "syrus/a", sha: "b" * 40)

    described_class.perform_now

    expect(BranchPublication.exists?(old.id)).to be(false)
    expect(BranchPublication.exists?(fresh.id)).to be(true)
  end
end
