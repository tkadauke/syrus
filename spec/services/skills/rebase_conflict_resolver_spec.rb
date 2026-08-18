require "rails_helper"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe Skills::RebaseConflictResolver do
  let(:user) { Factories.user(github_token: "ghp_test") }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets", default_branch: "trunk") }

  describe ".definition" do
    it "declares branch_name required and base_branch optional" do
      definition = described_class.definition

      expect(definition).to be_a(Skills::Definition)
      expect(definition.name).to eq("rebase-conflict-resolver")
      expect(definition.description).to match(/judgment-heavy/i)
      expect(definition.parameters.size).to eq(2)

      branch_name = definition.parameters.first
      expect(branch_name.key).to eq("branch_name")
      expect(branch_name.type).to eq("string")
      expect(branch_name.required).to eq(true)

      base_branch = definition.parameters.second
      expect(base_branch.key).to eq("base_branch")
      expect(base_branch.type).to eq("string")
      expect(base_branch.required).to eq(false)
    end

    it "renders the {{branch_name}} placeholder for Skills::Renderer to substitute" do
      expect(described_class.definition.instructions).to include("{{branch_name}}")
    end

    it "falls back to a generic description of the default branch without a repository" do
      expect(described_class.definition.instructions).to include("Rebase onto: the repository's default branch")
    end

    it "describes itself as manual-only, not an automatic hand-off target" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/manual invocation\s+only/i)
      expect(instructions).to match(/nothing in Syrus currently\s+hands off to it\s+automatically/i)
    end

    it "instructs the agent to escalate past mechanical resolution with real judgment" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/resolve with judgment, not just mechanically/i)
      expect(instructions).to match(/make a considered judgment call/i)
    end

    it "instructs the agent that this produces a new PR for review, not an overwrite of the original branch" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/does \*\*not\*\*\s+automatically force-push or overwrite the original conflicted\s+branch/i)
    end

    it "instructs the agent not to guess when it cannot resolve the conflict with confidence" do
      instructions = described_class.definition.instructions

      expect(instructions).to match(/do not guess/i)
      expect(instructions).to match(/leave the working tree exactly as you found it/i)
      expect(instructions).to match(/valid, successful\s+outcome/i)
    end

    it "does not report an automated pre-scan without a workspace_path" do
      expect(described_class.definition.instructions).not_to include("Automated pre-scan results")
    end
  end

  describe ".definition(repository:, args:)" do
    it "resolves the base branch from the repository's default branch when not submitted" do
      instructions = described_class.definition(repository: repository).instructions

      expect(instructions).to include("Rebase onto: trunk")
    end

    it "prefers an explicitly submitted base_branch over the repository default" do
      instructions = described_class.definition(repository: repository, args: { "base_branch" => "develop" }).instructions

      expect(instructions).to include("Rebase onto: develop")
    end
  end

  describe ".definition(workspace_path:)" do
    around do |ex|
      Dir.mktmpdir("syrus-rebase-conflict-skill") { |dir| @dir = dir; ex.run }
    end

    def write(rel, contents)
      path = File.join(@dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, contents)
    end

    def git(*args)
      out, err, status = Open3.capture3(
        { "GIT_AUTHOR_NAME" => "T", "GIT_AUTHOR_EMAIL" => "t@e", "GIT_COMMITTER_NAME" => "T", "GIT_COMMITTER_EMAIL" => "t@e" },
        "git", "-C", @dir, *args
      )
      raise "git #{args.join(' ')} failed:\n#{out}\n#{err}" unless status.success?
      out
    end

    def instructions_for(**opts)
      described_class.definition(workspace_path: @dir, **opts).instructions
    end

    it "reports a clean checkout as not conflicted" do
      Open3.capture3("git", "init", "-q", "-b", "main", @dir)
      write("README.md", "hello\n")
      git("add", ".")
      git("commit", "-q", "-m", "initial")

      instructions = instructions_for(args: { "branch_name" => "feature" })

      expect(instructions).to include("Automated pre-scan results")
      expect(instructions).to match(/not\s+currently mid-rebase or mid-merge/)
      expect(instructions).to match(/finds no unmerged files/)
    end

    it "surfaces a real in-progress rebase conflict against a fixture repo" do
      Open3.capture3("git", "init", "-q", "-b", "main", @dir)
      write("shared.rb", "BASE\n")
      git("add", ".")
      git("commit", "-q", "-m", "base")

      git("checkout", "-q", "-b", "feature")
      write("shared.rb", "FEATURE\n")
      git("add", ".")
      git("commit", "-q", "-m", "feature edit")

      git("checkout", "-q", "main")
      write("shared.rb", "MAIN\n")
      git("add", ".")
      git("commit", "-q", "-m", "main edit")

      git("checkout", "-q", "feature")
      # Deliberately do not check success: this is expected to conflict and
      # leave the workspace mid-rebase, which is exactly the fixture state
      # this skill is meant to be invoked against.
      Open3.capture3(
        { "GIT_AUTHOR_NAME" => "T", "GIT_AUTHOR_EMAIL" => "t@e", "GIT_COMMITTER_NAME" => "T", "GIT_COMMITTER_EMAIL" => "t@e" },
        "git", "-C", @dir, "rebase", "main"
      )

      instructions = instructions_for(args: { "branch_name" => "feature" })

      expect(instructions).to include("Automated pre-scan results")
      expect(instructions).to match(/Rebase in progress: true/)
      expect(instructions).to include("shared.rb")
      expect(instructions).to match(/Finish resolving the conflict already present here/)
    end
  end

  describe "not wired into the automated rebase pipeline" do
    AUTOMATED_REBASE_STEP_FILES = %w[
      app/services/auto_rebase.rb
      app/services/stack_rebase_plan.rb
      app/services/steps/auto_rebase.rb
      app/services/steps/agent_rebase.rb
      app/services/steps/force_push.rb
      app/services/steps/stack_auto_rebase.rb
      app/services/steps/stack_agent_rebase.rb
      app/services/steps/stack_force_push.rb
      app/services/steps/push_agent_rebase.rb
      app/services/steps/push_after_rebase.rb
      app/services/steps/merge_train_rebase.rb
      app/services/steps/merge_train_land_after_rebase.rb
    ].freeze

    it "is registered as an explicitly-launchable built-in skill" do
      expect(Skills::Registry.values).to include("rebase-conflict-resolver")
      expect(Skills::Registry.class_for("rebase-conflict-resolver")).to eq(described_class)
    end

    it "is never referenced by the deterministic/agentic rebase pipeline steps, so it cannot silently auto-run" do
      AUTOMATED_REBASE_STEP_FILES.each do |relative_path|
        path = Rails.root.join(relative_path)
        next unless path.exist?

        source = path.read
        expect(source).not_to match(/RebaseConflictResolver/), "#{relative_path} unexpectedly references RebaseConflictResolver"
        expect(source).not_to match(/rebase-conflict-resolver/), "#{relative_path} unexpectedly references the rebase-conflict-resolver skill name"
      end
    end
  end
end
