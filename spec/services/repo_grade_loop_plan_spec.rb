require "rails_helper"

RSpec.describe RepoGradeLoopPlan do
  def loaded(config: nil, source: "none", note: nil)
    RepoDefaultBranchSyrusYml::Result.new(config: config, source: source, note: note)
  end

  def parse(yaml)
    SyrusYml.new(yaml).parse
  end

  describe ".from_syrus_yml" do
    it "is unconfigured when the shared loader has no config" do
      result = described_class.from_syrus_yml(loaded(note: "no GitHub credentials"))

      expect(result).not_to be_any_configured
      expect(result.note).to eq("no GitHub credentials")
    end

    it "is unconfigured when none of formatters/generated/grade are declared" do
      config = parse("prepare: []\n")

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result.format_configured).to eq(false)
      expect(result.generate_configured).to eq(false)
      expect(result.graders_configured).to eq(false)
      expect(result).not_to be_any_configured
    end

    it "reports format_configured when formatters is a non-empty array" do
      config = parse(<<~YAML)
        formatters:
          - command: rubocop -a
            files: "**/*.rb"
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result.format_configured).to eq(true)
      expect(result.generate_configured).to eq(false)
      expect(result.graders_configured).to eq(false)
      expect(result).to be_any_configured
    end

    it "reports generate_configured when generated is a non-empty array" do
      config = parse(<<~YAML)
        generated:
          - command: bin/rails db:schema:dump
            generates: "db/schema.rb"
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result.generate_configured).to eq(true)
      expect(result.format_configured).to eq(false)
      expect(result.graders_configured).to eq(false)
      expect(result).to be_any_configured
    end

    it "reports graders_configured when grade steps are declared" do
      config = parse(<<~YAML)
        grade:
          - name: tests
            run: bin/rspec
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result.graders_configured).to eq(true)
      expect(result.format_configured).to eq(false)
      expect(result.generate_configured).to eq(false)
      expect(result).to be_any_configured
    end

    it "is unconfigured when formatters/generated are explicitly disabled and grade has no steps" do
      config = parse(<<~YAML)
        formatters: false
        generated: false
        grade: []
      YAML

      result = described_class.from_syrus_yml(loaded(config: config, source: ".syrus.yml"))

      expect(result).not_to be_any_configured
    end
  end

  describe ".for_job" do
    it "resolves through RepoDefaultBranchSyrusYml.for_job" do
      job = instance_double(Job)
      allow(RepoDefaultBranchSyrusYml).to receive(:for_job).with(job).and_return(loaded(note: "no .syrus.yml"))

      result = described_class.for_job(job)

      expect(result).not_to be_any_configured
      expect(result.note).to eq("no .syrus.yml")
    end
  end
end
