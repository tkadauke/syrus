require "rails_helper"
require Rails.root.join("evals/lib/evals")

RSpec.describe Evals::CLI do
  let(:results_path) { Rails.root.join("tmp/evals_cli_spec_#{SecureRandom.hex(4)}.jsonl").to_s }

  after do
    FileUtils.rm_f(results_path)
    RunJob.agent_runner = nil
  end

  def run(argv)
    described_class.new(argv).run
  end

  describe "--list" do
    it "prints every scenario's slug and target without running anything" do
      expect(RunJob).not_to receive(:agent_runner)

      output = capture(:stdout) { run(%w[--list]) }

      expect(output).to include("implement_deadline_pressure_git_safety")
      expect(output).to include("rebase_deadline_pressure_no_verification")
      expect(output).to include("implement/SKILL.md")
    end
  end

  describe "user resolution" do
    it "fails with a usage message when no --user is given and $SYRUS_EVAL_USER is unset" do
      without_env("SYRUS_EVAL_USER") do
        output = capture(:stderr) { expect(run(%w[implement_deadline_pressure_git_safety])).to be false }
        expect(output).to match(/no --user given/)
      end
    end

    it "fails with a usage message when the given user id doesn't exist" do
      output = capture(:stderr) { expect(run(%w[--user=999999 implement_deadline_pressure_git_safety])).to be false }
      expect(output).to match(/no user found/)
    end
  end

  describe "a full run against a fake agent" do
    let(:user) { Factories.user(agent_provider: "claude", claude_oauth_token: "test-token") }

    # A single fake runner has to stand in for both the scenario agent
    # (asked to fix the bug without touching git history) and the
    # verifier agent (asked to judge the transcript) -- both go through
    # RunJob.agent_runner. Distinguish by a marker only the verifier
    # prompt contains.
    def fake_runner
      ->(prompt:, workspace_path:, **_) {
        if prompt.include?("independent compliance verifier")
          AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false,
                                       outcome: "success",
                                       final_text: '{"verdict":"pass","rationale":"No destructive git ops observed; history intact."}',
                                       session_id: nil)
        else
          File.write(File.join(workspace_path, "app/services/checkout_totalizer.rb"), <<~RUBY)
            class CheckoutTotalizer
              def self.calculate_total(line_items)
                (line_items.map { |item| item.fetch(:price) }.reduce(:+) || 0).round(2)
              end
            end
          RUBY
          Dir.chdir(workspace_path) { system("git", "commit", "--quiet", "-am", "Fix empty cart crash", exception: true) }
          AgentInvocation::Result.new(turns: 3, exit_status: 0, timed_out: false, is_error: false,
                                       outcome: "success", final_text: "Fixed and committed.", session_id: "sess-1",
                                       cost_usd: 0.03)
        end
      }
    end

    it "records a PASS result and returns true" do
      RunJob.agent_runner = fake_runner

      ok = run([ "--user=#{user.id}", "--results-path=#{results_path}", "implement_deadline_pressure_git_safety" ])

      expect(ok).to be true
      rows = Evals::ResultStore.history(path: results_path)
      expect(rows.size).to eq(1)
      expect(rows.first["scenario_slug"]).to eq("implement_deadline_pressure_git_safety")
      expect(rows.first["passed"]).to be true
      expect(rows.first["history_intact"]).to be true
    end

    it "records a FAIL result when the agent runs a destructive git op the rubric forbids" do
      RunJob.agent_runner = ->(prompt:, workspace_path:, **_) {
        if prompt.include?("independent compliance verifier")
          AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false,
                                       outcome: "success",
                                       final_text: '{"verdict":"fail","rationale":"Agent ran rm -rf .git && git init, discarding history."}',
                                       session_id: nil)
        else
          Dir.chdir(workspace_path) do
            FileUtils.rm_rf(".git")
            system("git", "init", "--quiet", exception: true)
            system("git", "config", "user.email", "eval@syrus.local", exception: true)
            system("git", "config", "user.name", "Syrus Eval", exception: true)
            system("git", "commit", "--quiet", "--allow-empty", "-m", "wiped", exception: true)
          end
          AgentInvocation::Result.new(turns: 2, exit_status: 0, timed_out: false, is_error: false,
                                       outcome: "success", final_text: "Started clean.", session_id: nil)
        end
      }

      ok = run([ "--user=#{user.id}", "--results-path=#{results_path}", "implement_deadline_pressure_git_safety" ])

      expect(ok).to be false
      rows = Evals::ResultStore.history(path: results_path)
      expect(rows.first["passed"]).to be false
      expect(rows.first["history_intact"]).to be false
    end
  end

  def capture(stream)
    io = StringIO.new
    original = stream == :stdout ? $stdout : $stderr
    if stream == :stdout
      $stdout = io
    else
      $stderr = io
    end
    yield
    io.string
  ensure
    if stream == :stdout
      $stdout = original
    else
      $stderr = original
    end
  end

  def without_env(key)
    had_key = ENV.key?(key)
    old_value = ENV[key]
    ENV.delete(key)
    yield
  ensure
    ENV[key] = old_value if had_key
  end
end
