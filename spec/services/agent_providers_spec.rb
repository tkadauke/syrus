require "rails_helper"

RSpec.describe AgentProviders do
  describe AgentProviders::Base do
    it "does not crash when an anonymous provider class uses the fallback key" do
      provider_class = Class.new(described_class)

      expect(provider_class.provider).to eq("unknown")
      expect(provider_class.provider_key).to eq("unknown")
    end

    it "defaults available_models to an empty array" do
      expect(described_class.available_models).to eq([])
    end

    it "persists estimated cost when an invocation reports tokens but no cost" do
      job = Factories.job_with_run(
        workflow_attrs: { agent_provider: "codex", model: "gpt-5.2-codex" },
        run_attrs: { agent_provider: "codex", model: "gpt-5.2-codex" }
      )
      run = job.runs.first
      provider_class = Class.new(described_class) do
        def self.provider = "codex"
      end
      adapter = provider_class.new(run: run, workspace: double(path: Rails.root), parent_session_id: nil)
      result = AgentInvocation::Result.new(
        turns: 1,
        exit_status: 0,
        timed_out: false,
        is_error: false,
        outcome: "success",
        final_text: nil,
        session_id: nil,
        input_tokens: 1_000_000,
        output_tokens: 100_000
      )

      adapter.record_result!(result, log: ->(*) { })

      expect(run.reload.cost_usd).to eq(BigDecimal("3.15"))
    end
  end

  describe ".for" do
    it "returns the registered provider adapter class" do
      expect(described_class.for("agy")).to eq(AgentProviders::Agy)
      expect(described_class.for("claude")).to eq(AgentProviders::Claude)
      expect(described_class.for("codex")).to eq(AgentProviders::Codex)
    end

    it "returns the Agy MCP tool label" do
      expect(Prompts::WorkflowMcpToolInstructions.tool_name_for("agy", "submit_summary"))
        .to eq("mcp(syrus-mcp-sidecar/submit_summary)")
    end

    it "raises a configuration error for unknown providers" do
      expect { described_class.for("oracle") }
        .to raise_error(AgentProviders::ConfigurationError, /Unknown agent provider/)
    end
  end

  describe ".run_one_shot" do
    let(:user) { Factories.user }
    let(:fake_result) { double(:result) }

    it "delegates to the Claude provider class method for claude provider" do
      expect(AgentProviders::Claude).to receive(:invoke_one_shot).with(
        hash_including(user: user, prompt: "hello", scope: "test-scope")
      ).and_return(fake_result)

      result = described_class.run_one_shot(
        provider: "claude",
        user: user,
        runner: nil,
        scope: "test-scope",
        prompt: "hello",
        log_sink: ->(*) { },
        timeout: 30,
        max_turns: 1
      )

      expect(result).to eq(fake_result)
    end

    it "delegates to the Codex provider class method for codex provider" do
      expect(AgentProviders::Codex).to receive(:invoke_one_shot).with(
        hash_including(user: user, scope: "test-scope")
      ).and_return(fake_result)

      described_class.run_one_shot(
        provider: "codex",
        user: user,
        runner: nil,
        scope: "test-scope",
        prompt: "hello",
        log_sink: ->(*) { },
        timeout: 30,
        max_turns: 1
      )
    end

    it "delegates to the Agy provider class method for agy provider" do
      expect(AgentProviders::Agy).to receive(:invoke_one_shot).with(
        hash_including(user: user, scope: "test-scope")
      ).and_return(fake_result)

      described_class.run_one_shot(
        provider: "agy",
        user: user,
        runner: nil,
        scope: "test-scope",
        prompt: "hello",
        log_sink: ->(*) { },
        timeout: 30,
        max_turns: 1
      )
    end

    it "sets and restores one-shot agent context around provider invocation" do
      agent = Agent.find_or_create_for!(Factories.run)
      prior_agent = Agent.find_or_create_for!(Factories.run)
      Thread.current[:syrus_current_agent] = prior_agent

      expect(AgentProviders::Codex).to receive(:invoke_one_shot) do
        expect(Thread.current[:syrus_current_agent]).to eq(agent)
        fake_result
      end

      described_class.run_one_shot(
        provider: "codex",
        user: user,
        runner: nil,
        scope: "test-scope",
        prompt: "hello",
        log_sink: ->(*) { },
        timeout: 30,
        max_turns: 1,
        agent: agent
      )

      expect(Thread.current[:syrus_current_agent]).to eq(prior_agent)
    ensure
      Thread.current[:syrus_current_agent] = nil
    end

    it "raises ConfigurationError for unknown provider" do
      expect {
        described_class.run_one_shot(
          provider: "oracle",
          user: user,
          runner: nil,
          scope: "test",
          prompt: "x",
          log_sink: ->(*) { },
          timeout: 30,
          max_turns: 1
        )
      }.to raise_error(AgentProviders::ConfigurationError, /Unknown agent provider/)
    end
  end
end
