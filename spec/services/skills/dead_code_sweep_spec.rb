require "rails_helper"
require "tmpdir"

RSpec.describe Skills::DeadCodeSweep do
  describe ".definition" do
    it "declares an optional apply_fixes boolean parameter defaulting to false" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("dead-code-sweep")
      expect(definition.description).to match(/unused/i)
      expect(definition.parameters.size).to eq(1)

      apply_fixes = definition.parameters.first
      expect(apply_fixes.key).to eq("apply_fixes")
      expect(apply_fixes.type).to eq("boolean")
      expect(apply_fixes.required).to eq(false)
      expect(apply_fixes.default).to eq(false)
    end

    it "renders the {{apply_fixes}} placeholder for Skills::Renderer to substitute" do
      expect(described_class.definition.instructions).to include("{{apply_fixes}}")
    end

    it "requires stating confidence and reasoning per finding instead of asserting certainty" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/never assert that a\s+finding definitely is dead code/i)
      expect(instructions).to match(/state your\s+confidence \(high\/medium\/low\)/i)
      expect(instructions).to match(/reasoning/i)
    end

    it "documents that a false apply_fixes always ends via the no_changes report-only path" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/apply fixes is not `true`/i)
      expect(instructions).to match(/do not edit, delete, or\s+commit anything/i)
      expect(instructions).to match(/always\s+closes without a diff/i)
    end

    it "documents that apply_fixes only removes files with zero inbound references" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/apply fixes is `true`/i)
      expect(instructions).to match(/unambiguous/i)
      expect(instructions).to match(/zero\s+inbound references anywhere in the repository/i)
      expect(instructions).to match(/only\s+whole files with zero inbound references qualify as unambiguous/i)
    end

    it "instructs the agent to revert and report instead of committing when grading fails" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/do not commit/i)
      expect(instructions).to match(/revert your changes/i)
      expect(instructions).to match(/leave the working tree exactly as you\s+found it/i)
    end

    it "documents language-appropriate static analysis for Ruby, JS\/TS, and Go" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/Ruby \(signal: `Gemfile`\)/)
      expect(instructions).to match(/JavaScript\/TypeScript \(signal: `package\.json`\)/)
      expect(instructions).to match(/Go \(signal: `go\.mod`\)/)
    end

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-dead-code-sweep-skill") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def instructions_for(**opts)
      described_class.definition(workspace_path: @dir, **opts).instructions
    end

    it "reports no detected languages for an empty repo" do
      instructions = instructions_for

      expect(instructions).to include("Automated pre-scan results")
      expect(instructions).to match(/Detected languages: none detected/)
    end

    it "detects Ruby from a Gemfile" do
      write("Gemfile", "source 'https://rubygems.org'\n")

      instructions = instructions_for

      expect(instructions).to match(/Ruby \(from `Gemfile`\)/)
    end

    it "detects JavaScript\/TypeScript from a package.json" do
      write("package.json", "{}")

      instructions = instructions_for

      expect(instructions).to match(%r{JavaScript/TypeScript \(from `package\.json`\)})
    end

    it "detects multiple languages at once for a poly-language repo" do
      write("Gemfile")
      write("package.json", "{}")
      write("go.mod", "module example.com/thing\n")

      instructions = instructions_for

      expect(instructions).to match(/Ruby \(from `Gemfile`\)/)
      expect(instructions).to match(%r{JavaScript/TypeScript \(from `package\.json`\)})
      expect(instructions).to match(/Go \(from `go\.mod`\)/)
    end

    it "still includes the full detection reference table alongside the concrete scan results" do
      instructions = instructions_for

      described_class::LANGUAGE_TOOLS.each { |entry| expect(instructions).to include("`#{entry[:signal]}`") }
    end
  end
end
