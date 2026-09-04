require "rails_helper"

RSpec.describe Judgment do
  let(:user) { Factories.user }

  def agent_result(text: "{}", timed_out: false, is_error: false, exit_status: 0, outcome: "success", cost_usd: nil)
    result = AgentInvocation::Result.new(
      turns: 1, exit_status: exit_status, timed_out: timed_out, is_error: is_error,
      outcome: outcome, final_text: text, session_id: nil
    )
    allow(result).to receive(:cost_usd).and_return(cost_usd) unless cost_usd.nil?
    result
  end

  def judge(result, **overrides)
    allow(AgentProviders).to receive(:run_one_shot).and_return(result)
    described_class.call(**{ scope: "test", prompt: "p", user: user, provider: "claude" }.merge(overrides))
  end

  it "returns the parsed answer" do
    outcome = judge(agent_result(text: JSON.generate("title" => "Fix the thing")))

    expect(outcome).to be_ok
    expect(outcome.value).to eq("title" => "Fix the thing")
  end

  # Agents fence their JSON about half the time; every copy of this re-derived
  # the same strip.
  it "strips a surrounding JSON fence" do
    outcome = judge(agent_result(text: "```json\n{\"title\":\"x\"}\n```"))

    expect(outcome.value).to eq("title" => "x")
  end

  it "passes its scope through to the provider" do
    expect(AgentProviders).to receive(:run_one_shot)
      .with(hash_including(provider: "claude", user: user, scope: "chat-title"))
      .and_return(agent_result)

    described_class.call(scope: "chat-title", prompt: "p", user: user, provider: "claude")
  end

  it "propagates a provider configuration error as an application problem" do
    allow(AgentProviders).to receive(:run_one_shot).and_raise(AgentProviders::ConfigurationError, "Unknown agent provider")

    outcome = described_class.call(scope: "test", prompt: "p", user: user, provider: "oracle")

    expect(outcome.problem.code).to eq("application_error")
    expect(outcome.error).to match(/Unknown agent provider/)
  end

  describe "declared output schema" do
    it "fails when a declared key is missing" do
      outcome = judge(agent_result(text: JSON.generate("reason" => "x")), schema: %w[title])

      expect(outcome).to be_failed
      expect(outcome.error).to match(/missing keys: title/)
    end

    it "accepts an answer carrying every declared key" do
      outcome = judge(agent_result(text: JSON.generate("title" => "x", "extra" => 1)), schema: %w[title])

      expect(outcome).to be_ok
    end
  end

  describe "guardrails the plan requires from day one" do
    # A timed-out judgment is a known Problem with a retry default, not an
    # exception each caller has to recognize.
    it "reports a timeout as a timeout Problem" do
      outcome = judge(agent_result(timed_out: true))

      expect(outcome.problem.code).to eq("timeout")
      expect(outcome.problem.default_remediation).to eq(:retry_step)
    end

    it "reports an agent error in the shared vocabulary" do
      outcome = judge(agent_result(is_error: true, outcome: "crashed"))

      expect(outcome.problem.code).to eq("application_error")
      expect(outcome.error).to match(/agent reported crashed/)
    end

    it "reports a non-zero exit in the shared vocabulary" do
      outcome = judge(agent_result(exit_status: 3))

      expect(outcome.error).to match(/agent exited 3/)
    end

    # A judgment costing more than the decision is worth is a bug, not a result.
    it "fails a judgment that ran over its cost ceiling" do
      outcome = judge(agent_result(text: JSON.generate("title" => "x"), cost_usd: 2.0), cost_ceiling_usd: 0.5)

      expect(outcome).to be_failed
      expect(outcome.error).to match(/exceeded ceiling/)
      expect(outcome.cost_usd).to eq(2.0)
    end

    it "allows a judgment inside its ceiling" do
      outcome = judge(agent_result(text: JSON.generate("title" => "x"), cost_usd: 0.1), cost_ceiling_usd: 0.5)

      expect(outcome).to be_ok
    end
  end

  it "reports unparseable output as a validation problem" do
    outcome = judge(agent_result(text: "not json"))

    expect(outcome.problem.code).to eq("validation_or_user_error")
    expect(outcome.error).to match(/invalid JSON/)
  end

  it "reports an empty response rather than parsing it" do
    outcome = judge(agent_result(text: "  "))

    expect(outcome.error).to eq("empty response")
  end
end
