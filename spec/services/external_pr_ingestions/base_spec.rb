require "rails_helper"

RSpec.describe ExternalPrIngestions::Base do
  describe ".for" do
    {
      "external_unknown" => ExternalPrIngestions::ExternalUnknown,
      "syrus_job_export" => ExternalPrIngestions::SyrusJobExport,
      "syrus_branch_export" => ExternalPrIngestions::SyrusBranchExport,
      "syrus_promotion" => ExternalPrIngestions::SyrusPromotion,
      "manual_hotfix" => ExternalPrIngestions::ManualHotfix
    }.each do |classification, klass|
      it "resolves #{classification.inspect} to #{klass}" do
        expect(described_class.for(classification)).to be_a(klass)
      end
    end

    it "falls back to ExternalUnknown for an unrecognized classification" do
      expect(described_class.for("something_new")).to be_a(ExternalPrIngestions::ExternalUnknown)
    end
  end
end
