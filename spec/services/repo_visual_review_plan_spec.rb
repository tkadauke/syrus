require "rails_helper"

RSpec.describe RepoVisualReviewPlan do
  def loaded(config: nil, source: "none", note: nil)
    RepoDefaultBranchSyrusYml::Result.new(config: config, source: source, note: note)
  end

  def parse(yaml)
    SyrusYml.new(yaml).parse
  end

  describe ".from_syrus_yml" do
    it "falls back to the instance default when the shared loader has no config" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(true)

      result = described_class.from_syrus_yml(loaded(note: "no GitHub credentials"))

      expect(result).to be_enabled
      expect(result.note).to eq("no GitHub credentials")
    end

    it "enables from the parsed config, overriding the instance default" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      config = parse(<<~YAML)
        visual_review:
          enabled: true
          rounds: 2
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).to be_enabled
      expect(result.rounds).to eq(2)
      expect(result.source).to eq(".syrus.yml")
    end

    it "defers to the instance default when the block is present but enabled is omitted" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      config = parse(<<~YAML)
        visual_review:
          rounds: 3
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).to be_enabled
      expect(result.rounds).to eq(3)
      expect(result.source).to eq(".syrus.yml")
    end

    it "disables via explicit repository opt-out, overriding an enabled instance default" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(true)
      config = parse(<<~YAML)
        visual_review:
          enabled: false
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).not_to be_enabled
      expect(result.source).to eq(".syrus.yml")
    end

    it "falls back to the instance-wide default when visual_review is not configured" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      config = parse("prepare: []\n")

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).not_to be_enabled
      expect(result.note).to eq("no visual_review configured")
    end
  end

  describe ".for_job" do
    it "resolves through RepoDefaultBranchSyrusYml.for_job" do
      allow(Feature).to receive(:visual_review_enabled?).and_return(false)
      job = instance_double(Job)
      allow(RepoDefaultBranchSyrusYml).to receive(:for_job).with(job).and_return(loaded(note: "GitHub client unavailable"))

      result = described_class.for_job(job)

      expect(result).not_to be_enabled
      expect(result.note).to eq("GitHub client unavailable")
    end
  end
end
