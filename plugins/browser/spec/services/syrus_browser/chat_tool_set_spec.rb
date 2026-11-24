require "rails_helper"

RSpec.describe SyrusBrowser::ChatToolSet do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }

  it "is shared with coworker chats, including visual review tools" do
    expect(Mcp::ChatToolParity.plugin_exceptions([ described_class ])).to be_empty
    expect(Mcp::ChatToolParity.plugin_report([ described_class ])).to eq([])
    names = described_class.tool_definitions(tier: :deferred).map { |definition| definition.fetch(:name) }
    expect(names).to include("run_visual_review", "run_visual_diff")
    expect(described_class.tool_definitions(tier: :deferred))
      .to all(satisfy { |definition| Mcp::ChatToolParity.plugin_definition_in_context?(definition, :coworker, provider: described_class) })
  end

  it "is offered to a coworker chat even with no browser runtime session, which errors precisely on use" do
    chat = ChatSession.create!(user: user, repository: repository, mode: "planning")
    allow(McpToolContext).to receive(:from_chat_session).with(chat).and_return(double(role: AgentRole::COWORKER_CHAT))

    expect(described_class.available_for?(chat, tier: :essential)).to be true
    expect { SyrusBrowser::SessionContext.resolve(chat_session: chat) }
      .to raise_error(SyrusBrowser::SessionContext::NoActiveSessionError, /no active browser runtime session/)
  end

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

    it "attaches scoped permission descriptors to every browser tool" do
      definitions = described_class.tool_definitions(tier: :essential)

      expect(definitions).to all(include(:capability_descriptor))
      expect(definitions.to_h { |definition| [ definition[:name], definition[:capability_descriptor].capability ] })
        .to include(
          "browser_navigate" => "browser.navigate@v1",
          "browser_evaluate" => "browser.execute@v1",
          "browser_file_upload" => "browser.upload@v1",
          "browser_drop" => "browser.upload@v1"
        )
    end

    it "classifies visual workflow requests as essential confirmation-card creation" do
      definitions = described_class.tool_definitions(tier: :deferred).index_by { |definition| definition[:name] }

      %w[run_visual_review run_visual_diff].each do |name|
        expect(definitions.fetch(name).fetch(:capability_descriptor)).to be_essential
      end
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
