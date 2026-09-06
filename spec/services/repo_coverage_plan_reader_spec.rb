require "rails_helper"

RSpec.describe RepoCoveragePlanReader do
  def loaded(config: nil, source: "none", note: nil)
    RepoDefaultBranchSyrusYml::Result.new(config: config, source: source, note: note)
  end

  def parse(yaml)
    SyrusYml.new(yaml).parse
  end

  describe ".from_syrus_yml" do
    it "returns nil when the shared loader has no config" do
      result = described_class.from_syrus_yml(loaded(note: "no GitHub credentials"))

      expect(result).to be_nil
    end

    it "returns the coverage plan from the parsed config" do
      config = parse(<<~YAML)
        coverage:
          sources:
            - artifact: coverage/lcov.info
              format: lcov
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).to be_a(RepoCoveragePlan)
      expect(result.sources.first.artifact).to eq("coverage/lcov.info")
    end

    it "returns nil when coverage is not configured" do
      config = parse("prepare: []\n")

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).to be_nil
    end
  end

  describe ".for_job" do
    it "resolves through RepoDefaultBranchSyrusYml.for_job" do
      job = instance_double(Job)
      allow(RepoDefaultBranchSyrusYml).to receive(:for_job).with(job).and_return(loaded(note: "no .syrus.yml"))

      result = described_class.for_job(job)

      expect(result).to be_nil
    end
  end
end
