require "rails_helper"
require "tmpdir"

RSpec.describe Skills::Debug do
  describe ".definition" do
    it "declares a required bug_description parameter" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("debug")
      expect(definition.description).to match(/reproduces/i)
      expect(definition.parameters.size).to eq(1)

      bug_description = definition.parameters.first
      expect(bug_description.key).to eq("bug_description")
      expect(bug_description.type).to eq("text")
      expect(bug_description.required).to eq(true)
    end

    it "renders the {{bug_description}} placeholder for Skills::Renderer to substitute" do
      expect(described_class.definition.instructions).to include("{{bug_description}}")
    end

    it "instructs the agent to reproduce the bug with a failing test before fixing it" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/failing (automated )?test/i)
      expect(instructions).to match(/root cause/i)
      expect(instructions).to match(/minimal fix/i)
    end

    it "explicitly discourages unrelated improvements beyond the reported bug" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/do not refactor/i)
      expect(instructions).to match(/scope is the reported bug only/i)
    end

    it "instructs the agent to report clearly and make no changes when reproduction fails" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/do not guess at a fix/i)
      expect(instructions).to match(/leave the working tree exactly as you found it/i)
      expect(instructions).to match(/no commit/i)
      expect(instructions).to match(/valid, successful\s+outcome/i)
    end

    it "reuses RepoGradeSignals' detection rules for picking a test framework" do
      instructions = described_class.definition.instructions

      RepoGradeSignals::RULE_DESCRIPTIONS.each do |rule|
        expect(instructions).to include(rule.name)
        expect(instructions).to include(rule.run)
      end
    end

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-debug-skill") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    it "reports no configured graders and no detected candidates for an empty repo" do
      instructions = described_class.definition(workspace_path: @dir).instructions

      expect(instructions).to include("Automated pre-scan results")
      expect(instructions).to match(/Configured graders \(`\.syrus\.yml`\): none configured/)
      expect(instructions).to match(/Auto-detected test\/lint candidates: none detected/)
    end

    it "surfaces graders already configured in .syrus.yml" do
      write(".syrus.yml", <<~YAML)
        grade:
          steps:
            - name: rspec
              run: bin/rspec
              required: true
      YAML

      instructions = described_class.definition(workspace_path: @dir).instructions

      expect(instructions).to match(/Configured graders \(`\.syrus\.yml`\): rspec \(`bin\/rspec`\)/)
    end

    it "falls back to auto-detected candidates when nothing is configured" do
      write("Gemfile")
      write("spec/spec_helper.rb")

      instructions = described_class.definition(workspace_path: @dir).instructions

      expect(instructions).to include("rspec (`bin/rspec`, evidence: spec/)")
    end

    it "still includes the full detection reference table alongside the concrete scan results" do
      instructions = described_class.definition(workspace_path: @dir).instructions

      RepoGradeSignals::RULE_DESCRIPTIONS.each { |rule| expect(instructions).to include(rule.name) }
    end
  end
end
