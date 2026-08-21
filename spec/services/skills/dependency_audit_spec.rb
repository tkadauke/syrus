require "rails_helper"
require "tmpdir"

RSpec.describe Skills::DependencyAudit do
  describe ".definition" do
    it "declares an optional dry_run boolean parameter defaulting to true" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("dependency-audit")
      expect(definition.description).to match(/audit/i)
      expect(definition.parameters.size).to eq(1)

      dry_run = definition.parameters.first
      expect(dry_run.key).to eq("dry_run")
      expect(dry_run.type).to eq("boolean")
      expect(dry_run.required).to eq(false)
      expect(dry_run.default).to eq(true)
    end

    it "renders the {{dry_run}} placeholder for Skills::Renderer to substitute" do
      expect(described_class.definition.instructions).to include("{{dry_run}}")
    end

    it "reuses RepoPrepPlan's lockfile signals for ecosystem detection" do
      instructions = described_class.definition.instructions

      Skills::DependencyAudit::ECOSYSTEMS.each_value do |signals|
        signals.each { |file, _command| expect(instructions).to include("`#{file}`") }
      end
    end

    it "documents the report-only path for a dry run" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/dry run is `true`/i)
      expect(instructions).to match(/do not edit any files/i)
      expect(instructions).to match(/make no commit/i)
    end

    it "documents the bump-and-commit path for a non-dry run, gated on the repo's own grade commands" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/bump each flagged dependency/i)
      expect(instructions).to match(/run this repository's own grade commands/i)
      expect(instructions).to match(/if those commands pass, commit/i)
    end

    it "instructs the agent to revert and report instead of committing when grading fails" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/do not commit/i)
      expect(instructions).to match(/revert your changes/i)
      expect(instructions).to match(/leave the\s+working tree exactly as you found it/i)
    end

    it "documents the no-vulnerabilities outcome as a valid, successful no-op" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/every audit command reports a clean result/i)
      expect(instructions).to match(/make no changes/i)
      expect(instructions).to match(/valid, successful\s+outcome/i)
      expect(instructions).to match(/closes without a diff/i)
    end

    it "warns against indiscriminate bulk-update commands" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/never an indiscriminate/i)
      expect(instructions).to match(/only touch the dependencies the audit flagged/i)
    end

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-dependency-audit-skill") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def instructions_for(**opts)
      described_class.definition(workspace_path: @dir, **opts).instructions
    end

    it "reports no detected ecosystems for an empty repo" do
      instructions = instructions_for

      expect(instructions).to include("Automated pre-scan results")
      expect(instructions).to match(/Detected ecosystems and audit commands: none detected/)
    end

    it "detects the Ruby ecosystem from a Gemfile and proposes bundle audit" do
      write("Gemfile", "source 'https://rubygems.org'\n")

      instructions = instructions_for

      expect(instructions).to match(/Ruby \(`bundle audit`, from `Gemfile`\)/)
    end

    it "detects the Node ecosystem from a package-lock.json and proposes npm audit" do
      write("package.json", "{}")
      write("package-lock.json", "{}")

      instructions = instructions_for

      expect(instructions).to match(/Node \(`npm audit`, from `package-lock\.json`\)/)
    end

    it "prefers yarn.lock over package-lock.json when both are present" do
      write("package-lock.json", "{}")
      write("yarn.lock", "")

      instructions = instructions_for

      expect(instructions).to match(/Node \(`yarn audit`, from `yarn\.lock`\)/)
      expect(instructions).not_to match(/from `package-lock\.json`/)
    end

    it "detects multiple ecosystems at once for a poly-ecosystem repo" do
      write("Gemfile")
      write("package-lock.json", "{}")

      instructions = instructions_for

      expect(instructions).to match(/Ruby \(`bundle audit`, from `Gemfile`\)/)
      expect(instructions).to match(/Node \(`npm audit`, from `package-lock\.json`\)/)
    end

    it "surfaces graders already configured in .syrus.yml" do
      write("Gemfile")
      write(".syrus.yml", <<~YAML)
        grade:
          steps:
            - name: rspec
              run: bin/rspec
              required: true
      YAML

      instructions = instructions_for

      expect(instructions).to match(/Configured graders \(`\.syrus\.yml`\): rspec \(`bin\/rspec`\)/)
    end

    it "falls back to auto-detected grade candidates when nothing is configured" do
      write("Gemfile")
      write("spec/spec_helper.rb")

      instructions = instructions_for

      expect(instructions).to include("rspec (`bin/rspec`, evidence: spec/)")
    end

    it "still includes the full detection reference table alongside the concrete scan results" do
      instructions = instructions_for

      Skills::DependencyAudit::ECOSYSTEMS.each_value do |signals|
        signals.each { |file, _command| expect(instructions).to include("`#{file}`") }
      end
    end
  end
end
