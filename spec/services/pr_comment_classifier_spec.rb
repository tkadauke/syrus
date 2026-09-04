require "rails_helper"

RSpec.describe PrCommentClassifier do
  let(:user) { Factories.user(claude_oauth_token: "oat-test") }

  def agent_result(text:, timed_out: false, is_error: false, exit_status: 0)
    AgentInvocation::Result.new(
      turns: 1,
      exit_status: exit_status,
      timed_out: timed_out,
      is_error: is_error,
      outcome: is_error ? "error" : "success",
      final_text: text,
      session_id: nil
    )
  end

  describe ".call" do
    it "returns actionable=true when agent classifies comment as actionable" do
      allow(AgentProviders).to receive(:run_one_shot).and_return(
        agent_result(text: JSON.generate("actionable" => true, "reason" => "requests a change"))
      )

      result = described_class.call(body: "Please fix the bug.", user: user, agent_provider: "claude")

      expect(result.success?).to be true
      expect(result.actionable).to be true
      expect(result.reason).to eq("requests a change")
    end

    it "returns actionable=false when agent classifies comment as non-actionable" do
      allow(AgentProviders).to receive(:run_one_shot).and_return(
        agent_result(text: JSON.generate("actionable" => false, "reason" => "just praise"))
      )

      result = described_class.call(body: "Great work!", user: user, agent_provider: "claude")

      expect(result.success?).to be true
      expect(result.actionable).to be false
      expect(result.reason).to eq("just praise")
    end

    it "returns a failure when the agent times out" do
      allow(AgentProviders).to receive(:run_one_shot).and_return(
        agent_result(text: nil, timed_out: true)
      )

      result = described_class.call(body: "hello", user: user, agent_provider: "claude")

      expect(result.success?).to be false
      expect(result.error).to match(/timed out/)
    end

    it "returns a failure when the agent exits with an error" do
      allow(AgentProviders).to receive(:run_one_shot).and_return(
        agent_result(text: nil, is_error: true, exit_status: 1)
      )

      result = described_class.call(body: "hello", user: user, agent_provider: "claude")

      expect(result.success?).to be false
      expect(result.error).to match(/agent reported/)
    end

    it "returns a failure when the response is not valid JSON" do
      allow(AgentProviders).to receive(:run_one_shot).and_return(
        agent_result(text: "not json at all")
      )

      result = described_class.call(body: "hello", user: user, agent_provider: "claude")

      expect(result.success?).to be false
      expect(result.error).to match(/invalid JSON/)
    end
  end
end
