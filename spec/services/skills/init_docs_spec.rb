require "rails_helper"
require "tmpdir"

RSpec.describe Skills::InitDocs do
  describe ".definition" do
    it "declares an optional target_file string and an optional dry_run boolean parameter" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("init-docs")
      expect(definition.description).to match(/CLAUDE\.md/)
      expect(definition.parameters.size).to eq(2)

      target_file = definition.parameters.first
      expect(target_file.key).to eq("target_file")
      expect(target_file.type).to eq("string")
      expect(target_file.required).to eq(false)
      expect(target_file.default).to eq("CLAUDE.md")

      dry_run = definition.parameters.second
      expect(dry_run.key).to eq("dry_run")
      expect(dry_run.type).to eq("boolean")
      expect(dry_run.required).to eq(false)
      expect(dry_run.default).to eq(false)
    end

    it "renders the {{target_file}} and {{dry_run}} placeholders for Skills::Renderer to substitute" do
      instructions = described_class.definition.instructions

      expect(instructions).to include("{{target_file}}")
      expect(instructions).to include("{{dry_run}}")
    end

    it "instructs the agent to generate a new file from scratch when none exists" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/does not exist.{0,60}generate one from\s+scratch/mi)
      expect(instructions).to match(/Stack/)
      expect(instructions).to match(/Architecture in brief/)
      expect(instructions).to match(/Key directories/)
      expect(instructions).to match(/Conventions/)
    end

    it "documents the preserve-marker convention and seeds an Operator notes section on first run" do
      instructions = described_class.definition.instructions

      expect(instructions).to include("<!-- syrus:init-docs:preserve -->")
      expect(instructions).to include("<!-- syrus:init-docs:preserve:end -->")
      expect(instructions).to match(/Operator notes/)
      expect(instructions).to match(/never edit, reformat, or remove it/i)
    end

    it "instructs the agent to refresh (not blindly regenerate) an existing file" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/refresh an existing target file/i)
      expect(instructions).to match(/Never edit, reformat, reorder, or remove anything between/i)
      expect(instructions).to match(/Update only what's actually stale/i)
      expect(instructions).to match(/This is a \*\*refresh\*\*,\s*not a rewrite/i)
    end

    it "instructs the agent to make no changes on a dry run" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/dry run is `true`, do not (create the file|write any changes)/i)
    end

    it "documents the no-op ending as a valid, successful outcome" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/valid, successful\s+outcome/i)
    end

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-init-docs-skill") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def instructions_for(**opts)
      described_class.definition(workspace_path: @dir, **opts).instructions
    end

    context "first run — no existing target file" do
      it "reports that the target file does not exist and lists top-level entries" do
        write("README.md")
        write("app/models/thing.rb")
        write("Gemfile")

        instructions = instructions_for

        expect(instructions).to include("Automated pre-scan results")
        expect(instructions).to match(/\(`CLAUDE\.md`\): does not exist\. Generate a new one from scratch/)
        expect(instructions).to match(/Top-level entries:.*`README\.md`/)
        expect(instructions).to match(/Top-level entries:.*`app`/)
        expect(instructions).to match(/Top-level entries:.*`Gemfile`/)
      end

      it "excludes noise directories like .git and node_modules from the top-level entries" do
        write(".git/HEAD")
        write("node_modules/left-pad/index.js")
        write("README.md")

        instructions = instructions_for

        expect(instructions).not_to match(/`\.git`/)
        expect(instructions).not_to match(/`node_modules`/)
        expect(instructions).to match(/`README\.md`/)
      end

      it "reports no preserved sections when there is nothing to preserve" do
        write("README.md")

        instructions = instructions_for

        expect(instructions).not_to match(/Preserve-marked section/)
      end

      it "honors a custom target_file argument" do
        write("AGENTS.md")

        instructions = instructions_for(args: { "target_file" => "AGENTS.md" })

        expect(instructions).to match(/\(`AGENTS\.md`\): already exists/)
      end
    end

    context "refresh — an existing target file with an operator-authored section" do
      it "extracts the preserve-marked section verbatim and instructs the agent to keep it" do
        write("CLAUDE.md", <<~DOC)
          # My Project

          Some generated overview text.

          ## Operator notes

          <!-- syrus:init-docs:preserve -->
          Deploys happen only on Tuesdays. Ask Jordan before touching the
          payments module.
          <!-- syrus:init-docs:preserve:end -->
        DOC

        instructions = instructions_for

        expect(instructions).to match(/\(`CLAUDE\.md`\): already exists\. Refresh it/)
        expect(instructions).to include("Preserve-marked section(s) found")
        expect(instructions).to include("Deploys happen only on Tuesdays. Ask Jordan before touching the")
        expect(instructions).to include("<!-- syrus:init-docs:preserve -->")
        expect(instructions).to include("<!-- syrus:init-docs:preserve:end -->")
      end

      it "extracts multiple preserve-marked sections independently" do
        write("CLAUDE.md", <<~DOC)
          <!-- syrus:init-docs:preserve -->
          First preserved block.
          <!-- syrus:init-docs:preserve:end -->

          Generated middle section.

          <!-- syrus:init-docs:preserve -->
          Second preserved block.
          <!-- syrus:init-docs:preserve:end -->
        DOC

        instructions = instructions_for

        expect(instructions).to include("First preserved block.")
        expect(instructions).to include("Second preserved block.")
        expect(instructions).to match(/1\..*2\./m)
      end

      it "reports an existing file with no preserved sections without fabricating one" do
        write("CLAUDE.md", "# My Project\n\nJust generated text, no operator notes yet.\n")

        instructions = instructions_for

        expect(instructions).to match(/\(`CLAUDE\.md`\): already exists\. Refresh it/)
        expect(instructions).not_to match(/Preserve-marked section/)
      end
    end
  end
end
