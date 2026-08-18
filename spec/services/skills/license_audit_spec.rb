require "rails_helper"
require "tmpdir"
require "fileutils"
require "json"

RSpec.describe Skills::LicenseAudit do
  describe ".definition" do
    it "declares an optional denied_licenses string parameter defaulting to GPL, AGPL" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("license-audit")
      expect(definition.description).to match(/license/i)
      expect(definition.parameters.size).to eq(1)

      denied_licenses = definition.parameters.first
      expect(denied_licenses.key).to eq("denied_licenses")
      expect(denied_licenses.type).to eq("string")
      expect(denied_licenses.required).to eq(false)
      expect(denied_licenses.default).to eq("GPL, AGPL")
    end

    it "renders the {{denied_licenses}} placeholder for Skills::Renderer to substitute" do
      expect(described_class.definition.instructions).to include("{{denied_licenses}}")
    end

    it "documents Ruby and Node ecosystem detection and their license-listing commands" do
      instructions = described_class.definition.instructions

      expect(instructions).to include("`Gemfile`")
      expect(instructions).to include("`bundle licenses`")
      expect(instructions).to include("`package-lock.json`")
      expect(instructions).to include("`npx license-checker --summary`")
      expect(instructions).to include("`yarn.lock`")
      expect(instructions).to include("`yarn licenses list`")
    end

    it "documents the report-only outcome: never edits, removes, or commits" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/report-only/i)
      expect(instructions).to match(/do not edit, remove, or replace any dependency/i)
      expect(instructions).to match(/make no\s+commit/i)
      expect(instructions).to match(/closes without a\s+diff/i)
    end

    it "documents flagging undeclared licenses separately from the deny-list match" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/no declared license/i)
      expect(instructions).to match(/manual review/i)
    end

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-license-audit-skill") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def write_node_package(rel_dir, attrs)
      write(File.join("node_modules", rel_dir, "package.json"), attrs.to_json)
    end

    def instructions_for(**opts)
      described_class.definition(workspace_path: @dir, **opts).instructions
    end

    it "reports no detected ecosystems for an empty repo" do
      instructions = instructions_for

      expect(instructions).to include("Automated pre-scan results")
      expect(instructions).to match(/Detected ecosystems and license commands: none detected/)
    end

    it "detects the Ruby ecosystem from a Gemfile and proposes bundle licenses" do
      write("Gemfile", "source 'https://rubygems.org'\n")

      instructions = instructions_for

      expect(instructions).to match(/Ruby \(`bundle licenses`, from `Gemfile`\)/)
    end

    it "detects the Node ecosystem from a package-lock.json and proposes npx license-checker" do
      write("package.json", "{}")
      write("package-lock.json", "{}")

      instructions = instructions_for

      expect(instructions).to match(/Node \(`npx license-checker --summary`, from `package-lock\.json`\)/)
    end

    context "with a node_modules tree" do
      before do
        write("package.json", "{}")
        write("package-lock.json", "{}")
        write_node_package("gpl-lib", name: "gpl-lib", version: "1.0.0", license: "GPL-3.0")
        write_node_package("mit-lib", name: "mit-lib", version: "2.0.0", license: "MIT")
        write_node_package("@scope/pkg", name: "@scope/pkg", version: "3.0.0", license: "AGPL-3.0")
        write_node_package("lgpl-lib", name: "lgpl-lib", version: "4.0.0", license: "LGPL-2.1")
        write_node_package("no-license-lib", name: "no-license-lib", version: "5.0.0")
      end

      it "flags the known copyleft fixture dependencies under the default policy" do
        instructions = instructions_for

        expect(instructions).to include("`gpl-lib` — GPL-3.0")
        expect(instructions).to include("`@scope/pkg` — AGPL-3.0")
      end

      it "does not flag a permissively-licensed dependency under the default policy" do
        instructions = instructions_for

        expect(instructions).not_to include("`mit-lib` —")
      end

      it "does not flag LGPL under a GPL deny entry (weaker copyleft, not implied by GPL)" do
        instructions = instructions_for

        expect(instructions).not_to include("`lgpl-lib` —")
      end

      it "calls out the dependency with no declared license separately" do
        instructions = instructions_for

        expect(instructions).to match(/1 package\(s\) declared no `license` field/)
      end

      it "reports the correct flagged and scanned counts under the default policy" do
        instructions = instructions_for

        expect(instructions).to match(/5 package\(s\) read, 2 flagged, 1 with no declared license/)
      end

      it "changes what's flagged when the denied_licenses policy is overridden" do
        instructions = instructions_for(args: { "denied_licenses" => "MIT" })

        expect(instructions).to include("`mit-lib` — MIT")
        expect(instructions).not_to include("`gpl-lib` —")
        expect(instructions).not_to include("`@scope/pkg` —")
        expect(instructions).to match(/5 package\(s\) read, 1 flagged, 1 with no declared license/)
      end

      it "reports no flagged dependencies when nothing matches an overridden policy" do
        instructions = instructions_for(args: { "denied_licenses" => "PROPRIETARY" })

        expect(instructions).to match(/No flagged dependencies against the current denied list\./)
      end
    end

    it "reports no installed packages when node_modules is empty" do
      write("package.json", "{}")
      FileUtils.mkdir_p(File.join(@dir, "node_modules"))

      instructions = instructions_for

      expect(instructions).to match(/no installed packages found/)
    end

    it "still includes the full detection reference table alongside the concrete scan results" do
      instructions = instructions_for

      Skills::LicenseAudit::ECOSYSTEMS.each_value do |signals|
        signals.each { |file, _command| expect(instructions).to include("`#{file}`") }
      end
    end
  end
end
