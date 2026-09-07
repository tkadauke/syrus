require "rails_helper"

RSpec.describe SyrusBrowser::ChatToolSet do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  describe ".available_for?" do
    it "is available for a Coding Mode chat at essential/deferred tiers" do
      chat = ChatSession.create!(user: user, repository: repository, mode: "coding")

      expect(described_class.available_for?(chat, tier: :essential)).to be true
      expect(described_class.available_for?(chat, tier: :deferred)).to be true
    end

    it "is not available for a planning chat" do
      chat = ChatSession.create!(user: user, repository: repository, mode: "planning")

      expect(described_class.available_for?(chat, tier: :essential)).to be false
    end

    it "is not available for a Local Mode chat" do
      chat = ChatSession.create!(user: user, repository: repository, mode: "local")

      expect(described_class.available_for?(chat, tier: :essential)).to be false
    end

    it "is not available outside the essential/deferred tiers" do
      chat = ChatSession.create!(user: user, repository: repository, mode: "coding")

      expect(described_class.available_for?(chat, tier: :evaluator)).to be false
    end
  end

  describe ".tool_definitions" do
    it "exposes the same tool set as the workflow McpToolSet" do
      expect(described_class.tool_definitions(tier: :essential).map { |d| d[:name] })
        .to match_array(SyrusBrowser::McpToolSet.tool_definitions.map { |d| d[:name] })
    end
  end

  describe "#handle" do
    it "delegates to McpToolSet's dispatch" do
      chat = ChatSession.create!(user: user, repository: repository, mode: "coding")
      response = MCP::Tool::Response.new([ { type: "text", text: "ok" } ])
      expect_any_instance_of(SyrusBrowser::McpToolSet).to receive(:handle)
        .with("browser_snapshot", {}, { chat_session: chat })
        .and_return(response)

      result = described_class.new.handle("browser_snapshot", {}, { chat_session: chat })

      expect(result).to eq(response)
    end
  end
end
