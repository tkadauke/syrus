require "rails_helper"

RSpec.describe RepoAdversarialReviewPlan do
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

    it "enables rounds from the parsed config" do
      config = parse(<<~YAML)
        adversarial_review:
          rounds: 2
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).to be_enabled
      expect(result.rounds).to eq(2)
      expect(result.source).to eq(".syrus.yml")
      expect(result.criteria).to eq([])
    end

    it "carries criteria from the parsed config" do
      config = parse(<<~YAML)
        adversarial_review:
          rounds: 1
          criteria:
            - Verify authentication on new endpoints
            - No internal state in error messages
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result.criteria).to eq([
        "Verify authentication on new endpoints",
        "No internal state in error messages"
      ])
    end

    it "is disabled when adversarial_review is not configured" do
      config = parse("prepare: []\n")

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).not_to be_enabled
      expect(result.note).to eq("no adversarial_review configured")
    end
  end

  describe ".for_job" do
    it "resolves through RepoDefaultBranchSyrusYml.for_job" do
      job = instance_double(Job)
      allow(RepoDefaultBranchSyrusYml).to receive(:for_job).with(job).and_return(loaded(note: "no .syrus.yml"))

      result = described_class.for_job(job)

      expect(result).not_to be_enabled
      expect(result.note).to eq("no .syrus.yml")
    end
  end
end
