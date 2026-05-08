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
end
