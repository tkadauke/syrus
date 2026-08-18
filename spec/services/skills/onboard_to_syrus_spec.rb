require "rails_helper"

RSpec.describe Skills::OnboardToSyrus do
  describe ".definition" do
    it "declares an optional dry_run boolean parameter" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("onboard-to-syrus")
      expect(definition.description).to match(/\.syrus\.yml/)
      expect(definition.parameters.size).to eq(1)

      dry_run = definition.parameters.first
      expect(dry_run.key).to eq("dry_run")
      expect(dry_run.type).to eq("boolean")
      expect(dry_run.required).to eq(false)
      expect(dry_run.default).to eq(false)
    end

    it "renders the {{dry_run}} placeholder for Skills::Renderer to substitute" do
      expect(described_class.definition.instructions).to include("{{dry_run}}")
    end

    it "reuses RepoPrepPlan's auto-detect table verbatim for the prepare: section" do
      instructions = described_class.definition.instructions

      RepoPrepPlan::AUTO_DETECT.each do |file, command|
        expect(instructions).to include("`#{file}`")
        expect(instructions).to include("`#{command}`")
      end
    end

    it "lists every RepoGradeSignals detection rule for the grade: section" do
      instructions = described_class.definition.instructions

      RepoGradeSignals::RULE_DESCRIPTIONS.each do |rule|
        expect(instructions).to include(rule.name)
        expect(instructions).to include(rule.run)
      end
    end

    it "documents the grade.steps schema fields" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/`name`/)
      expect(instructions).to match(/`run`/)
      expect(instructions).to match(/`required`/)
      expect(instructions).to match(/`timeout_minutes`/)
    end

    it "instructs the agent to never overwrite an existing .syrus.yml and produce a gap analysis instead" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/already exists/i)
      expect(instructions).to match(/gap analysis/i)
      expect(instructions).to match(/do not overwrite|not overwrite|leave it untouched/i)
    end

    it "instructs the agent to make no changes on a dry run" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/dry run is `true`/i)
      expect(instructions).to match(/do not create, modify, or write any files/i)
    end

    it "documents the no-op ending as a valid, successful outcome" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/valid, successful\s+outcome/i)
    end

    it "checks for existing CI config to reuse its commands" do
      instructions = described_class.definition.instructions

      expect(instructions).to include(".github/workflows")
    end
  end
end
