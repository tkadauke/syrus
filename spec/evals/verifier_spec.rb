require "rails_helper"
require Rails.root.join("evals/lib/evals")

RSpec.describe Evals::Verifier do
  let(:scenario) { Evals::Scenarios.load("implement_deadline_pressure_git_safety") }
  let(:run_result) do
    Evals::AgentRun::Result.new(
      success: true, timed_out: false, is_error: false, outcome: "success",
      final_text: nil, transcript_text: "[assistant] done", cost_usd: 0.01, turns: 3,
      diff: "diff --git a/foo b/foo\n", history_intact: true
    )
  end
  let(:user) { instance_double(User, claude_oauth_token: nil) }

  def fake_runner_returning(text)
    ->(**_) { AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: text, session_id: nil) }
  end

  describe ".call" do
    it "invokes the configured agent provider's one-shot path and parses a passing verdict" do
      RunJob.agent_runner = fake_runner_returning('{"verdict":"pass","rationale":"No destructive git ops observed."}')

      verdict = described_class.call(scenario: scenario, run_result: run_result, user: user, provider: "claude")

      expect(verdict.passed).to be true
      expect(verdict.rationale).to eq("No destructive git ops observed.")
      expect(verdict.error).to be_nil
    ensure
      RunJob.agent_runner = nil
    end

    it "includes the rubric, the deterministic history_intact flag, and the transcript in the prompt sent to the verifier" do
      seen_prompt = nil
      RunJob.agent_runner = ->(prompt:, **_) {
        seen_prompt = prompt
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", final_text: '{"verdict":"fail","rationale":"x"}', session_id: nil)
      }

      described_class.call(scenario: scenario, run_result: run_result, user: user, provider: "claude")

      expect(seen_prompt).to include(scenario.rubric)
      expect(seen_prompt).to include("git_history_intact: true")
      expect(seen_prompt).to include("[assistant] done")
    ensure
      RunJob.agent_runner = nil
    end
  end

  describe ".parse" do
    def result(final_text:, **overrides)
      defaults = { turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success", session_id: nil }
      AgentInvocation::Result.new(**defaults.merge(overrides), final_text: final_text)
    end

    it "parses a clean JSON verdict" do
      verdict = described_class.parse(result(final_text: '{"verdict":"pass","rationale":"ok"}'))
      expect(verdict.passed).to be true
      expect(verdict.error).to be_nil
    end

    it "strips a ```json fence" do
      verdict = described_class.parse(result(final_text: "```json\n{\"verdict\":\"fail\",\"rationale\":\"nope\"}\n```"))
      expect(verdict.passed).to be false
      expect(verdict.rationale).to eq("nope")
    end

    it "reports a verifier error on timeout instead of a verdict" do
      verdict = described_class.parse(result(final_text: nil, timed_out: true))
      expect(verdict.passed).to be false
      expect(verdict.error).to eq("timed out")
    end

    it "reports a verifier error when the agent errored" do
      verdict = described_class.parse(result(final_text: nil, is_error: true, outcome: "error_max_turns"))
      expect(verdict.passed).to be false
      expect(verdict.error).to eq("agent reported error_max_turns")
    end

    it "reports a verifier error on unparsable JSON" do
      verdict = described_class.parse(result(final_text: "not json"))
      expect(verdict.passed).to be false
      expect(verdict.error).to match(/invalid JSON/)
    end

    it "reports a verifier error on an unrecognized verdict value" do
      verdict = described_class.parse(result(final_text: '{"verdict":"maybe","rationale":"?"}'))
      expect(verdict.passed).to be false
      expect(verdict.error).to match(/unrecognized verdict/)
    end
  end
end
