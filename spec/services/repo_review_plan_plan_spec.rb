require "rails_helper"

RSpec.describe RepoReviewPlanPlan do
  def loaded(config: nil, source: "none", note: nil)
    RepoDefaultBranchSyrusYml::Result.new(config: config, source: source, note: note)
  end

  def parse(yaml)
    SyrusYml.new(yaml).parse
  end

  describe ".from_syrus_yml" do
    it "is disabled when the shared loader has no config" do
      result = described_class.from_syrus_yml(loaded(note: "no GitHub credentials"))

      expect(result).not_to be_enabled
      expect(result.note).to eq("no GitHub credentials")
    end

    it "enables from the parsed config" do
      config = parse("review_plan: true\n")

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).to be_enabled
      expect(result.source).to eq(".syrus.yml")
      expect(result.note).to be_nil
    end

    it "is disabled when review_plan is not configured" do
      config = parse("prepare: []\n")

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).not_to be_enabled
      expect(result.source).to eq(".syrus.yml")
    end

    it "is disabled when review_plan is explicitly false" do
      config = parse("review_plan: false\n")

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).not_to be_enabled
    end
  end

  describe ".for_job" do
    it "resolves through RepoDefaultBranchSyrusYml.for_job" do
      job = instance_double(Job)
      allow(RepoDefaultBranchSyrusYml).to receive(:for_job).with(job).and_return(loaded(note: "GitHub client unavailable"))

      result = described_class.for_job(job)

      expect(result).not_to be_enabled
      expect(result.note).to eq("GitHub client unavailable")
    end
  end
end
