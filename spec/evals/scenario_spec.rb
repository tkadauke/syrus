require "rails_helper"
require Rails.root.join("evals/lib/evals")

RSpec.describe Evals::Scenarios do
  describe ".slugs and .all" do
    it "discovers the seed scenarios shipped under evals/scenarios/" do
      expect(described_class.slugs).to include(
        "implement_deadline_pressure_git_safety",
        "rebase_deadline_pressure_no_verification"
      )
      expect(described_class.all.map(&:slug)).to match_array(described_class.slugs)
    end
  end

  describe ".load" do
    it "raises a clear error for an unknown slug" do
      expect { described_class.load("does_not_exist") }.to raise_error(ArgumentError, /no scenario found/)
    end

    it "parses an implement scenario's fields from scenario.yml" do
      scenario = described_class.load("implement_deadline_pressure_git_safety")

      expect(scenario.skill).to eq("implement")
      expect(scenario.target).to include("implement/SKILL.md")
      expect(scenario.issue_title).to include("checkout page down")
      expect(scenario.issue_body).to include("rm -rf .git")
      expect(scenario.rubric).to include("git_history_intact")
      expect(scenario.fixture_dir).to end_with("implement_deadline_pressure_git_safety/fixture_repo")
      expect(scenario.setup_script).to be_nil
      expect(scenario.history_ancestor_ref).to be_nil
      expect(scenario.max_turns).to eq(40)
      expect(scenario.timeout_seconds).to eq(900)
    end

    it "parses a rebase scenario's fields, including the rebase context and history_ancestor_ref" do
      scenario = described_class.load("rebase_deadline_pressure_no_verification")

      expect(scenario.skill).to eq("rebase")
      expect(scenario.rebase_context).to eq(
        "repo_slug" => "acme/checkout-service",
        "branch_name" => "feature/checkout-empty-cart",
        "base_branch" => "release",
        "pr_number" => 482
      )
      expect(scenario.history_ancestor_ref).to eq("release")
      expect(scenario.setup_script).to end_with("rebase_deadline_pressure_no_verification/setup.rb")
    end
  end

  describe "#prompt" do
    it "renders the implement/SKILL.md prompt for an implement scenario, with the issue content substituted" do
      scenario = described_class.load("implement_deadline_pressure_git_safety")

      prompt = scenario.prompt

      expect(prompt).to include(scenario.issue_title)
      expect(prompt).to include("rm -rf .git")
      expect(prompt).to include("Git pipeline contract")
      expect(prompt).to include("NEVER run any of these mid-run")
    end

    it "renders the rebase/SKILL.md prompt for a rebase scenario, with the branch/base substituted" do
      scenario = described_class.load("rebase_deadline_pressure_no_verification")

      prompt = scenario.prompt

      expect(prompt).to include("feature/checkout-empty-cart")
      expect(prompt).to include("release")
      expect(prompt).to include("acme/checkout-service##{482}")
      expect(prompt).to include("resolve them mechanically")
    end

    it "raises for an unknown skill" do
      scenario = Evals::Scenario.new(slug: "bogus", skill: "not_a_real_skill")
      expect { scenario.prompt }.to raise_error(ArgumentError, /unknown skill/)
    end
  end
end
