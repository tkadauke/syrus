require "rails_helper"

RSpec.describe PrSummarizer do
  let(:issue) { Struct.new(:title, :body).new("Add greeting helper", "We need a greeting helper.") }
  let(:diff)  { "diff --git a/feature.rb b/feature.rb\n+def greet = 'hi'\n" }

  def fake_agent_returning(text, **overrides)
    defaults = { turns: 1, exit_status: 0, timed_out: false, is_error: false, outcome: "success" }
    instance_double("AgentProviders::Base", run_once: AgentInvocation::Result.new(**defaults.merge(overrides), final_text: text, session_id: nil))
  end

  def call(agent:)
    described_class.new(issue: issue, diff: diff, agent: agent).call
  end

  describe "#call (success paths)" do
    it "parses a clean JSON object into title + body" do
      result = call(agent: fake_agent_returning(
        '{"title":"Add greeting helper","body":"Adds a tiny greet helper."}'
      ))
      expect(result).to be_success
      expect(result.title).to eq("Add greeting helper")
      expect(result.body).to eq("Adds a tiny greet helper.")
    end

    it "strips a surrounding ```json fence the agent sometimes adds" do
      result = call(agent: fake_agent_returning(
        "```json\n{\"title\":\"Fix typo\",\"body\":\"Fixes a typo in greet.\"}\n```"
      ))
      expect(result).to be_success
      expect(result.title).to eq("Fix typo")
      expect(result.body).to eq("Fixes a typo in greet.")
    end

    it "strips a bare ``` fence (no json language tag)" do
      result = call(agent: fake_agent_returning(
        "```\n{\"title\":\"Fix typo\",\"body\":\"Fixes a typo.\"}\n```"
      ))
      expect(result).to be_success
      expect(result.title).to eq("Fix typo")
    end

    it "preserves embedded \\n in the body" do
      result = call(agent: fake_agent_returning(
        '{"title":"Add greeting helper","body":"para 1\nbody\n\npara 2"}'
      ))
      expect(result).to be_success
      expect(result.body).to eq("para 1\nbody\n\npara 2")
    end
  end

  describe "#call (failure paths)" do
    it "returns failure when the JSON does not parse" do
      result = call(agent: fake_agent_returning("totally not json"))
      expect(result).not_to be_success
      expect(result.error).to match(/invalid JSON/)
    end

    it "returns failure when the title is empty" do
      result = call(agent: fake_agent_returning('{"title":"","body":"x"}'))
      expect(result).not_to be_success
      expect(result.error).to eq("empty title")
    end

    it "returns failure when the title is excessively long" do
      result = call(agent: fake_agent_returning(
        { title: "A" * 200, body: "x" }.to_json
      ))
      expect(result).not_to be_success
      expect(result.error).to match(/title too long/)
    end

    it "returns failure when the agent timed out" do
      agent = instance_double(
        "AgentProviders::Base",
        run_once: AgentInvocation::Result.new(turns: 1, exit_status: nil, timed_out: true,
                                              is_error: false, outcome: nil, final_text: nil, session_id: nil)
      )
      result = call(agent: agent)
      expect(result).not_to be_success
      expect(result.error).to match(/timed out/)
    end

    it "returns failure when the agent reported is_error" do
      agent = instance_double(
        "AgentProviders::Base",
        run_once: AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false,
                                              is_error: true, outcome: "error_max_turns", final_text: nil, session_id: nil)
      )
      result = call(agent: agent)
      expect(result).not_to be_success
      expect(result.error).to match(/error_max_turns/)
    end

    it "returns failure when the agent exited non-zero" do
      agent = instance_double(
        "AgentProviders::Base",
        run_once: AgentInvocation::Result.new(turns: 1, exit_status: 2, timed_out: false,
                                              is_error: false, outcome: nil, final_text: nil, session_id: nil)
      )
      result = call(agent: agent)
      expect(result).not_to be_success
      expect(result.error).to match(/exited 2/)
    end

    it "returns failure when final_text is blank" do
      result = call(agent: fake_agent_returning(""))
      expect(result).not_to be_success
      expect(result.error).to eq("empty response")
    end

    it "rescues unexpected exceptions and returns a failure Result" do
      agent = instance_double("AgentProviders::Base")
      allow(agent).to receive(:run_once).and_raise("boom")
      result = call(agent: agent)
      expect(result).not_to be_success
      expect(result.error).to match(/RuntimeError: boom/)
    end
  end

  describe "provider adapter wiring" do
    it "uses the provider's one-shot invocation" do
      seen = {}
      agent = double("agent")
      allow(agent).to receive(:run_once) do |**kwargs|
        seen.merge!(kwargs)
        AgentInvocation::Result.new(turns: 1, exit_status: 0, timed_out: false, is_error: false,
                                    outcome: "success", final_text: '{"title":"x","body":"y"}', session_id: nil)
      end

      result = described_class.new(issue: issue, diff: diff, agent: agent).call

      expect(result).to be_success
      expect(seen[:prompt]).to include("Add greeting helper")
      expect(seen[:timeout]).to eq(described_class::DEFAULT_TIMEOUT_SECONDS)
      expect(seen[:max_turns]).to eq(1)
    end
  end
end
