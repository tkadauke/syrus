require "rails_helper"

RSpec.describe AgentProviders do
  describe ".for" do
    it "returns the registered provider adapter class" do
      expect(described_class.for("claude")).to eq(AgentProviders::Claude)
      expect(described_class.for("codex")).to eq(AgentProviders::Codex)
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
        log_sink: ->(*) {},
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
        log_sink: ->(*) {},
        timeout: 30,
        max_turns: 1
      )
    end

    it "raises ConfigurationError for unknown provider" do
      expect {
        described_class.run_one_shot(
          provider: "oracle",
          user: user,
          runner: nil,
          scope: "test",
          prompt: "x",
          log_sink: ->(*) {},
          timeout: 30,
          max_turns: 1
        )
      }.to raise_error(AgentProviders::ConfigurationError, /Unknown agent provider/)
    end
  end
end
