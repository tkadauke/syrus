require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe Skills::SecurityReview do
  describe ".definition" do
    it "declares an optional apply_fixes boolean parameter defaulting to false" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("security-review")
      expect(definition.description).to match(/OWASP|injection|secret/i)
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

    it "documents reviewing the current diff via a three-dot diff, falling back to the whole repo" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/git diff <default-branch>\.\.\.HEAD/)
      expect(instructions).to match(/three-dot, not\s+two-dot/i)
      expect(instructions).to match(/review the\s+repository as a whole instead/i)
    end

    it "documents OWASP-top-10-style categories, injection risks, and secret leakage" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/Injection/)
      expect(instructions).to match(/Broken access control/i)
      expect(instructions).to match(/Cryptographic failures/i)
      expect(instructions).to match(/Server-side request forgery/i)
      expect(instructions).to match(/Secret leakage/i)
    end

    it "distinguishes itself from the dependency-audit and license-audit skills" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/not a dependency scan/i)
      expect(instructions).to match(/`dependency-audit`/)
      expect(instructions).to match(/`license-audit`/)
    end

    it "documents that a false apply_fixes always ends via the report-only no_changes path" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/apply fixes is not `true`/i)
      expect(instructions).to match(/do not edit, delete, or\s+commit anything/i)
      expect(instructions).to match(/always\s+closes without a diff/i)
    end

    it "documents that apply_fixes only touches clearly-scoped, unambiguous findings" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/apply fixes is `true`/i)
      expect(instructions).to match(/clearly-scoped, unambiguous/i)
      expect(instructions).to match(/[Nn]ever\s+perform a broad refactor/)
      expect(instructions).to match(/never invent\s+a fake secret value/i)
    end

    it "instructs the agent to revert and report instead of committing when grading fails" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/do not commit/i)
      expect(instructions).to match(/revert your changes/i)
      expect(instructions).to match(/leave the working tree exactly as you\s+found it/i)
    end

    it "instructs the agent never to echo a matched secret's actual value" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/[Dd]o not (?:repeat|include) a matched secret's actual value/)
    end

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-security-review-skill") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def instructions_for(**opts)
      described_class.definition(workspace_path: @dir, **opts).instructions
    end

    it "reports no detected languages and no secrets for an empty repo" do
      instructions = instructions_for

      expect(instructions).to include("Automated pre-scan results")
      expect(instructions).to match(/Detected languages and recommended static analysis tools: none detected/)
      expect(instructions).to match(/no likely secrets found/)
    end

    it "detects Ruby from a Gemfile and recommends Brakeman/Rubocop Security" do
      write("Gemfile", "source 'https://rubygems.org'\n")

      instructions = instructions_for

      expect(instructions).to match(/Ruby \(from `Gemfile`\)/)
      expect(instructions).to include("bundle exec brakeman")
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

    # report-only path against a fixture with a known injectable/leaked pattern
    context "with a fixture containing a known hardcoded-secret pattern" do
      before do
        write("config/settings.rb", <<~RUBY)
          module Settings
            AWS_ACCESS_KEY_ID = "AKIAABCDEFGHIJKLMNOP"
          end
        RUBY
      end

      it "flags the fixture finding by file, line, and pattern label" do
        instructions = instructions_for

        expect(instructions).to match(%r{`config/settings\.rb:2` — AWS Access Key ID})
      end

      it "never echoes the matched secret's actual value into the instructions" do
        instructions = instructions_for

        expect(instructions).not_to include("AKIAABCDEFGHIJKLMNOP")
      end

      it "defaults to apply_fixes=false, so the rendered instructions still require report-only behavior" do
        instructions = instructions_for

        expect(instructions).to include("Apply fixes: {{apply_fixes}}")
        expect(instructions).to match(/apply fixes is not `true`/i)
      end
    end

    # apply_fixes path against an unambiguous fixture finding
    context "with a fixture containing an unambiguous single hardcoded credential" do
      before do
        write("lib/client.rb", <<~RUBY)
          class Client
            API_KEY = "supersecretvalue123"
          end
        RUBY
      end

      it "flags the credential assignment and documents the scoped fix an apply_fixes=true run should make" do
        instructions = instructions_for(args: { "apply_fixes" => "true" })

        expect(instructions).to match(%r{`lib/client\.rb:2` — Hardcoded credential assignment})
        expect(instructions).to match(/Apply fixes: \{\{apply_fixes\}\}/)
        expect(instructions).to match(/removing one hardcoded secret and replacing it\s+with a reference to this repo's existing configuration/i)
      end
    end

    it "detects a private key block" do
      write("id_rsa", "-----BEGIN RSA PRIVATE KEY-----\nMIIBogIBAAKCAQ==\n-----END RSA PRIVATE KEY-----\n")

      instructions = instructions_for

      expect(instructions).to match(%r{`id_rsa:1` — Private key block})
    end

    it "excludes vendored/dependency directories from the secret pre-scan" do
      write("node_modules/some-lib/index.js", 'const key = "AKIAABCDEFGHIJKLMNOP";')

      instructions = instructions_for

      expect(instructions).to match(/no likely secrets found/)
    end

    it "reports the scanned file count alongside any findings" do
      write("README.md", "hello")
      write("app/models/user.rb", "class User; end\n")

      instructions = instructions_for

      expect(instructions).to match(/2 file\(s\) scanned, no likely secrets found/)
    end

    it "truncates the secret pre-scan past its findings cap and notes the truncation" do
      (described_class::MAX_SECRET_FINDINGS + 5).times do |i|
        write("secrets/leak_#{i}.rb", %(TOKEN_#{i} = "AKIAABCDEFGHIJKLMNOP"\n))
      end

      instructions = instructions_for

      expect(instructions).to match(/#{described_class::MAX_SECRET_FINDINGS} likely secret\(s\) found/)
      expect(instructions).to match(/additional matches were not shown/)
    end

    it "still includes the full detection reference table alongside the concrete scan results" do
      instructions = instructions_for

      Skills::SecurityReview::SECURITY_TOOLS.each { |entry| expect(instructions).to include("`#{entry[:signal]}`") }
    end
  end
end
