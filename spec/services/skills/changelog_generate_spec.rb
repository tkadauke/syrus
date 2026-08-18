require "rails_helper"
require "tmpdir"
require "open3"

RSpec.describe Skills::ChangelogGenerate do
  describe ".definition" do
    it "declares since, format, and dry_run parameters with the documented defaults" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("changelog-generate")
      expect(definition.description).to match(/merged PRs/i)
      expect(definition.parameters.size).to eq(3)

      since = definition.parameters.first
      expect(since.key).to eq("since")
      expect(since.type).to eq("string")
      expect(since.required).to eq(false)
      expect(since.default).to be_nil

      format = definition.parameters.second
      expect(format.key).to eq("format")
      expect(format.type).to eq("text")
      expect(format.required).to eq(false)
      expect(format.default).to eq(Skills::ChangelogGenerate::DEFAULT_FORMAT)
      expect(format.default).to match(/Keep a Changelog/i)

      dry_run = definition.parameters.third
      expect(dry_run.key).to eq("dry_run")
      expect(dry_run.type).to eq("boolean")
      expect(dry_run.required).to eq(false)
      expect(dry_run.default).to eq(false)
    end

    it "renders the {{since}}, {{format}}, and {{dry_run}} placeholders for Skills::Renderer to substitute" do
      instructions = described_class.definition.instructions

      expect(instructions).to include("{{since}}")
      expect(instructions).to include("{{format}}")
      expect(instructions).to include("{{dry_run}}")
    end

    it "instructs the agent to read git/PR history only, never the GitHub API" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/git and PR history only/i)
      expect(instructions).to match(/do not\s+call the GitHub API/i)
      expect(instructions).to match(/no GitHub API credentials/i)
    end

    it "documents both squash-merge and merge-commit PR detection patterns" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/Squash merge/i)
      expect(instructions).to match(/\(#123\)/)
      expect(instructions).to match(/Merge pull\s+request #123 from/i)
    end

    it "documents the zero-findings outcome as a valid, successful no-op" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/find zero merged PRs\/commits/i)
      expect(instructions).to match(/valid, successful\s+outcome/i)
      expect(instructions).to match(/closes without a diff and without a PR/i)
    end

    it "documents the dry_run report-only path" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/dry run is `true`/i)
      expect(instructions).to match(/do not create or edit any file/i)
      expect(instructions).to match(/make no commit/i)
    end

    it "documents writing and committing when dry_run is false" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/dry run is not `true`/i)
      expect(instructions).to match(/write the change to the changelog file\s+and commit it/i)
    end

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe "format override" do
    it "substitutes a custom format via Skills::Renderer" do
      definition = described_class.definition
      custom_format = "One flat bullet list, no headings, newest entry first."

      rendered = Skills::Renderer.render(definition, "format" => custom_format)

      expect(rendered).to include(custom_format)
      expect(rendered).not_to include(described_class::DEFAULT_FORMAT)
    end

    it "falls back to the default Keep a Changelog format when no override is submitted" do
      definition = described_class.definition

      rendered = Skills::Renderer.render(definition, {})

      expect(rendered).to include(described_class::DEFAULT_FORMAT)
    end
  end

  describe "dry_run parameter rendering" do
    it "renders true when dry_run is submitted" do
      rendered = Skills::Renderer.render(described_class.definition, "dry_run" => true)

      expect(rendered).to match(/Dry run: true/)
    end

    it "defaults to false when dry_run is not submitted" do
      rendered = Skills::Renderer.render(described_class.definition, {})

      expect(rendered).to match(/Dry run: false/)
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-changelog-generate-skill") { |dir| @dir = dir; ex.run }
    end

    def git!(*args)
      env = {
        "GIT_AUTHOR_NAME" => "Test", "GIT_AUTHOR_EMAIL" => "test@example.com",
        "GIT_COMMITTER_NAME" => "Test", "GIT_COMMITTER_EMAIL" => "test@example.com"
      }
      _out, err, status = Open3.capture3(env, "git", *args, chdir: @dir)
      raise "git #{args.join(' ')} failed: #{err}" unless status.success?
    end

    def write(rel, contents = "")
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def instructions_for(**opts)
      described_class.definition(workspace_path: @dir, **opts).instructions
    end

    context "no git repository present" do
      it "reports no existing changelog file and no candidates, without raising" do
        write("README.md")

        instructions = instructions_for

        expect(instructions).to include("Automated pre-scan results")
        expect(instructions).to match(/Existing changelog file: none found/)
        expect(instructions).to match(/could not run `git log`/)
      end
    end

    context "entry generation against a fixture PR history" do
      before do
        git!("init", "-q")
        write("README.md", "hello\n")
        git!("add", "README.md")
        git!("commit", "-q", "-m", "Initial commit")
        git!("tag", "v1.0.0")

        # Squash-merge style: GitHub's default leaves the PR title as the
        # commit subject, suffixed with the PR number.
        write("search.rb", "search\n")
        git!("add", "search.rb")
        git!("commit", "-q", "-m", "Add search feature (#101)")

        # Merge-commit style: a real two-parent merge with the PR summary
        # in the merge commit's body.
        git!("checkout", "-q", "-b", "feature-x")
        write("ranking.rb", "ranking\n")
        git!("add", "ranking.rb")
        git!("commit", "-q", "-m", "wip ranking tweaks")
        git!("checkout", "-q", "-")
        git!(
          "merge", "-q", "--no-ff", "--no-edit",
          "-m", "Merge pull request #124 from acme/feature-x",
          "-m", "Implement search ranking overhaul.",
          "feature-x"
        )

        # A direct commit with no PR reference at all.
        write("timeout.rb", "timeout\n")
        git!("add", "timeout.rb")
        git!("commit", "-q", "-m", "Bump internal request timeout")
      end

      it "auto-detects the last tag and lists squash, merge-commit, and direct-commit candidates" do
        instructions = instructions_for

        expect(instructions).to match(/Starting point \(`since`\): `v1\.0\.0` \(auto-detected last tag\)/)
        expect(instructions).to match(/PR #101: Add search feature/)
        expect(instructions).to match(/PR #124: Implement search ranking overhaul\./)
        expect(instructions).to match(/commit `\h{10}` \(no PR reference found\): Bump internal request timeout/)
        expect(instructions).to match(/3 candidate\(s\) found/)
      end

      it "does not list the individual feature-branch commit merged behind the PR #124 merge commit" do
        instructions = instructions_for

        expect(instructions).not_to match(/wip ranking tweaks/)
      end

      it "honors an explicit since argument over the auto-detected tag" do
        git!("tag", "v1.1.0")

        instructions = instructions_for(args: { "since" => "v1.0.0" })

        expect(instructions).to match(/Starting point \(`since`\): `v1\.0\.0` \(given `since` parameter\)/)
        expect(instructions).to match(/PR #101/)
      end

      it "reports no candidates when nothing has landed since the starting point" do
        instructions = instructions_for(args: { "since" => "HEAD" })

        expect(instructions).to match(/none found — nothing has landed since the starting point/)
      end

      it "detects an existing CHANGELOG.md and instructs updating it in place" do
        write("CHANGELOG.md", "# Changelog\n\n## [1.0.0]\n- Initial release\n")

        instructions = instructions_for

        expect(instructions).to match(/Existing changelog file: `CHANGELOG\.md` already exists\. Update it in place/)
        expect(instructions).to match(/never rewrite its existing entries/i)
      end

      it "detects an alternate conventional changelog filename" do
        write("CHANGES.md", "# Changes\n")

        instructions = instructions_for

        expect(instructions).to match(/Existing changelog file: `CHANGES\.md` already exists/)
      end
    end

    context "repository with no tags yet" do
      it "falls back to full history and says so plainly" do
        git!("init", "-q")
        write("README.md", "hello\n")
        git!("add", "README.md")
        git!("commit", "-q", "-m", "Initial commit (#1)")

        instructions = instructions_for

        expect(instructions).to match(/Starting point \(`since`\): no tags found — using full history/)
        expect(instructions).to match(/PR #1: Initial commit/)
      end
    end
  end
end
