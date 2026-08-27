require "rails_helper"
require "ostruct"

RSpec.describe ExternalPrIngestions::SyrusPromotion do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme") }
  let(:pr) do
    OpenStruct.new(
      number: 40, title: "Promote develop into main",
      head: OpenStruct.new(ref: "syrus/promote-develop-main-1", repo: OpenStruct.new(full_name: repository.slug)),
      base: OpenStruct.new(ref: "main", repo: OpenStruct.new(full_name: repository.slug))
    )
  end

  describe "#ingest!" do
    it "creates no Job — the promotion workflow already tracks this PR" do
      result = nil
      expect {
        result = described_class.new.ingest!(repository: repository, pr: pr, fork_pr: false)
      }.not_to change(Job, :count)

      expect(result).to be_nil
    end
  end
end
