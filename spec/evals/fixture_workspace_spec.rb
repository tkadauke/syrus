require "rails_helper"
require Rails.root.join("evals/lib/evals")

RSpec.describe Evals::FixtureWorkspace, :ci_only do
  around do |example|
    @paths_to_clean = []
    example.run
    @paths_to_clean.each { |p| described_class.cleanup(p) }
  end

  def build(scenario)
    described_class.build(scenario).tap { |path| @paths_to_clean << path }
  end

  describe ".build" do
    it "seeds the fixture repo's files as an initial git commit" do
      scenario = Evals::Scenarios.load("implement_deadline_pressure_git_safety")

      path = build(scenario)

      expect(File).to exist(File.join(path, "app/services/checkout_totalizer.rb"))
      Dir.chdir(path) do
        expect(`git log --oneline`.lines.size).to eq(1)
        expect(`git status --porcelain`).to be_empty
      end
    end

    it "runs a scenario's setup.rb after the seed commit, leaving the workspace on the scripted branch" do
      scenario = Evals::Scenarios.load("rebase_deadline_pressure_no_verification")

      path = build(scenario)

      Dir.chdir(path) do
        expect(`git branch --show-current`.strip).to eq("feature/checkout-empty-cart")
        expect(`git log --oneline --all`.lines.size).to eq(3)
        expect(`git remote`.strip).to eq("origin")
      end
    end
  end

  describe ".history_intact?" do
    it "is true when HEAD still descends from the given ref" do
      scenario = Evals::Scenarios.load("implement_deadline_pressure_git_safety")
      path = build(scenario)
      base_sha = described_class.head_sha(path)

      Dir.chdir(path) do
        File.write("app/services/checkout_totalizer.rb", "# a normal follow-up commit\n")
        system("git", "commit", "--quiet", "-am", "Follow-up change", exception: true)
      end

      expect(described_class.history_intact?(path, base_sha)).to be true
    end

    it "is false when the working tree was reinitialized (orphaned history)" do
      scenario = Evals::Scenarios.load("implement_deadline_pressure_git_safety")
      path = build(scenario)
      base_sha = described_class.head_sha(path)

      Dir.chdir(path) do
        FileUtils.rm_rf(".git")
        system("git", "init", "--quiet", exception: true)
        system("git", "config", "user.email", "eval@syrus.local", exception: true)
        system("git", "config", "user.name", "Syrus Eval", exception: true)
        system("git", "commit", "--quiet", "--allow-empty", "-m", "orphaned", exception: true)
      end

      expect(described_class.history_intact?(path, base_sha)).to be false
    end

    it "is false when .git no longer exists at all" do
      scenario = Evals::Scenarios.load("implement_deadline_pressure_git_safety")
      path = build(scenario)
      base_sha = described_class.head_sha(path)
      FileUtils.rm_rf(File.join(path, ".git"))

      expect(described_class.history_intact?(path, base_sha)).to be false
    end
  end

  describe ".diff" do
    it "reports changes made after the base ref" do
      scenario = Evals::Scenarios.load("implement_deadline_pressure_git_safety")
      path = build(scenario)
      base_sha = described_class.head_sha(path)

      Dir.chdir(path) do
        File.write("app/services/checkout_totalizer.rb", "# changed\n")
        system("git", "commit", "--quiet", "-am", "Change it", exception: true)
      end

      expect(described_class.diff(path, base_sha)).to include("changed")
    end
  end
end
