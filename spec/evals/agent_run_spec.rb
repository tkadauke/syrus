require "rails_helper"
require Rails.root.join("evals/lib/evals")

RSpec.describe Evals::AgentRun, :ci_only do
  let(:scenario) { Evals::Scenarios.load("implement_deadline_pressure_git_safety") }
  let(:user) { instance_double(User, claude_oauth_token: nil) }
  let(:workspace_path) { Evals::FixtureWorkspace.build(scenario) }

  after { Evals::FixtureWorkspace.cleanup(workspace_path) }

  describe ".call" do
    it "invokes the agent with the scenario's rendered prompt and captures diff/transcript/history_intact" do
      seen_prompt = nil
      RunJob.agent_runner = ->(prompt:, workspace_path:, **_) {
        seen_prompt = prompt
        File.write(File.join(workspace_path, "app/services/checkout_totalizer.rb"), "# fixed\n")
        Dir.chdir(workspace_path) do
          system("git", "commit", "--quiet", "-am", "Fix the bug", exception: true)
        end
        AgentInvocation::Result.new(turns: 2, exit_status: 0, timed_out: false, is_error: false,
                                     outcome: "success", final_text: "done", session_id: "sess-1",
                                     transcript_jsonl: nil, cost_usd: 0.02)
      }

      result = described_class.call(scenario: scenario, workspace_path: workspace_path, user: user, provider: "claude")

      expect(seen_prompt).to eq(scenario.prompt)
      expect(result.success).to be true
      expect(result.turns).to eq(2)
      expect(result.cost_usd).to eq(0.02)
      expect(result.diff).to include("fixed")
      expect(result.history_intact).to be true
    ensure
      RunJob.agent_runner = nil
    end

    it "reports history_intact: false when the agent orphans the repo's git history" do
      RunJob.agent_runner = ->(workspace_path:, **_) {
        Dir.chdir(workspace_path) do
          FileUtils.rm_rf(".git")
          system("git", "init", "--quiet", exception: true)
          system("git", "config", "user.email", "eval@syrus.local", exception: true)
          system("git", "config", "user.name", "Syrus Eval", exception: true)
          system("git", "commit", "--quiet", "--allow-empty", "-m", "orphaned", exception: true)
        end
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false,
                                     outcome: "success", final_text: "done", session_id: nil)
      }

      result = described_class.call(scenario: scenario, workspace_path: workspace_path, user: user, provider: "claude")

      expect(result.history_intact).to be false
    ensure
      RunJob.agent_runner = nil
    end
  end
end
