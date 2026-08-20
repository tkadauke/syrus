require "rails_helper"
require "tmpdir"

RSpec.describe Skills::AddCiWorkflow do
  describe ".definition" do
    it "declares an optional dry_run boolean parameter defaulting to false" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("add-ci-workflow")
      expect(definition.description).to match(/CI/)
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

    it "instructs the agent to prefer .syrus.yml's grade section, ci: variant first" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/grade.*section/i)
      expect(instructions).to match(/prefer the `ci:` command/i)
    end

    it "falls back to the same grade-signal detection table onboard-to-syrus uses" do
      instructions = described_class.definition.instructions

      RepoGradeSignals::RULE_DESCRIPTIONS.each do |rule|
        expect(instructions).to include(rule.name)
        expect(instructions).to include(rule.run)
      end
    end

    it "checks for GitHub Actions and other CI systems before touching anything" do
      instructions = described_class.definition.instructions

      expect(instructions).to include(".github/workflows")
      Skills::AddCiWorkflow::OTHER_CI_SIGNALS.each do |rel, system|
        expect(instructions).to include(rel)
        expect(instructions).to include(system)
      end
    end

    it "instructs the agent to never overwrite existing CI config and produce a gap report instead" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/do not create, overwrite, or reorder/i)
      expect(instructions).to match(/gap report/i)
    end

    it "documents the no-op ending as a valid, successful outcome" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/valid,\s*\n?\s*successful\s+outcome/i)
    end

    it "instructs the agent to make no changes on a dry run" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/dry run is `true`/i)
      expect(instructions).to match(/do not create or write any file/i)
    end

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-add-ci-workflow") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def instructions_for(**opts)
      described_class.definition(workspace_path: @dir, **opts).instructions
    end

    context "bootstrap path — no existing CI config" do
      it "reports no existing CI config and no resolved commands for an empty repo" do
        instructions = instructions_for

        expect(instructions).to include("Automated pre-scan results")
        expect(instructions).to match(/Resolved command set: none/)
        expect(instructions).to match(/Existing CI config: none found/)
        expect(instructions).to match(/Gaps.*n\/a — no existing CI config to compare against/)
      end

      it "resolves the command set from .syrus.yml's grade section, preferring ci: over run:" do
        write(".syrus.yml", <<~YAML)
          grade:
            steps:
              - name: rspec
                run: bin/rspec-fast
                ci: bin/rspec-ci
                required: true
              - name: rubocop
                run: bundle exec rubocop
                required: true
        YAML

        instructions = instructions_for

        expect(instructions).to include("rspec (`bin/rspec-ci`, source: .syrus.yml (grade section))")
        expect(instructions).to include("rubocop (`bundle exec rubocop`, source: .syrus.yml (grade section))")
        expect(instructions).not_to include("bin/rspec-fast`")
      end

      it "falls back to auto-detected grade candidates when no grade section is configured" do
        write("Gemfile")
        write("spec/spec_helper.rb")
        write(".rubocop.yml")

        instructions = instructions_for

        expect(instructions).to include("rspec (`bin/rspec`, source: auto-detected (grade signals))")
        expect(instructions).to include("rubocop (`bundle exec rubocop`, source: auto-detected (grade signals))")
      end
    end

    context "gap-report path — existing CI config found" do
      it "detects an existing GitHub Actions workflow and reports which resolved commands are missing" do
        write(".syrus.yml", <<~YAML)
          grade:
            steps:
              - name: rspec
                run: bin/rspec-fast
                ci: bin/rspec-ci
                required: true
              - name: rubocop
                run: bundle exec rubocop
                required: true
        YAML
        write(".github/workflows/ci.yml", <<~YAML)
          jobs:
            test:
              steps:
                - run: bin/rspec-ci
        YAML

        instructions = instructions_for

        expect(instructions).to match(%r{Existing CI config: \.github/workflows/ci\.yml \(GitHub Actions\)})
        expect(instructions).to match(/Gaps.*rubocop \(`bundle exec rubocop`\)/)
        expect(instructions).not_to match(/Gaps.*rspec \(`bin\/rspec-ci`\)/)
      end

      it "reports no gaps when the existing CI config already covers every resolved command" do
        write(".syrus.yml", <<~YAML)
          grade:
            steps:
              - name: rspec
                run: bin/rspec
                required: true
        YAML
        write(".github/workflows/ci.yml", <<~YAML)
          jobs:
            test:
              steps:
                - run: bin/rspec
        YAML

        instructions = instructions_for

        expect(instructions).to match(/Gaps.*none — every resolved command already appears in the existing CI config/)
      end

      it "detects evidence of a non-GitHub-Actions CI system" do
        write("Gemfile")
        write("spec/spec_helper.rb")
        write("Jenkinsfile", "pipeline { stages { stage('test') { steps { sh 'bin/rspec' } } } }")

        instructions = instructions_for

        expect(instructions).to match(/Existing CI config: Jenkinsfile \(Jenkins\)/)
      end
    end

    it "still includes the full grade-signal reference table alongside the concrete scan results" do
      instructions = instructions_for

      RepoGradeSignals::RULE_DESCRIPTIONS.each { |rule| expect(instructions).to include(rule.name) }
    end
  end
end
