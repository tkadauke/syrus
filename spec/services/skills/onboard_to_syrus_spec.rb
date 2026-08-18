require "rails_helper"
require "tmpdir"

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

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-onboard-to-syrus") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "reports no existing .syrus.yml and no detected signals for an empty repo" do
      instructions = described_class.definition(workspace_path: @dir).instructions

      expect(instructions).to include("Automated pre-scan results")
      expect(instructions).to match(/`\.syrus\.yml`: does not exist/)
      expect(instructions).to match(/Detected prepare command: none/)
      expect(instructions).to match(/Detected grade candidates: none detected/)
      expect(instructions).to match(/Existing CI workflows: none found/)
    end

    it "reports the detected prepare command and grade candidates for a Ruby repo" do
      write("Gemfile", "source 'https://rubygems.org'\n")
      write("spec/spec_helper.rb")
      write(".rubocop.yml")

      instructions = described_class.definition(workspace_path: @dir).instructions

      expect(instructions).to match(/Detected prepare command: `bundle install`/)
      expect(instructions).to include("rspec (`bin/rspec`, evidence: spec/)")
      expect(instructions).to include("rubocop (`bundle exec rubocop`, evidence: .rubocop.yml)")
    end

    it "reports existing CI workflow paths and extracted run commands" do
      write("Gemfile")
      write(".github/workflows/ci.yml", <<~YAML)
        jobs:
          test:
            steps:
              - run: bin/rspec-ci
      YAML

      instructions = described_class.definition(workspace_path: @dir).instructions

      expect(instructions).to match(%r{Existing CI workflows: \.github/workflows/ci\.yml})
      expect(instructions).to include("run commands seen: bin/rspec-ci")
    end

    it "tells the agent an existing .syrus.yml must not be overwritten" do
      write(".syrus.yml", "prepare:\n  - bundle install\n")

      instructions = described_class.definition(workspace_path: @dir).instructions

      expect(instructions).to match(/`\.syrus\.yml`: already exists.*do not overwrite it/i)
    end

    it "still includes the full reference tables alongside the concrete scan results" do
      instructions = described_class.definition(workspace_path: @dir).instructions

      RepoPrepPlan::AUTO_DETECT.each { |file, _command| expect(instructions).to include("`#{file}`") }
      RepoGradeSignals::RULE_DESCRIPTIONS.each { |rule| expect(instructions).to include(rule.name) }
    end
  end
end
