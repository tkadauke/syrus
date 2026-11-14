require "rails_helper"

RSpec.describe AgentMemory::ChatToolSet do
  let!(:bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  before do
    PluginRecord.find_or_create_by!(name: "agent_memory").update!(enabled: true, disableable: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "returns the ordinary chat definitions for a coworker chat" do
    allow(McpToolContext).to receive(:from_chat_session).with(chat_session).and_return(
      instance_double(McpToolContext, role: AgentRole::COWORKER_CHAT)
    )

    definitions = %i[essential deferred].flat_map do |tier|
      described_class.tool_definitions(tier: tier, chat_session: chat_session)
    end

    expect(definitions.map { |definition| definition.fetch(:name) }).to contain_exactly(
      "write_memory", "read_memory", "search_memories", "list_memories", "delete_memory",
      "publish_memory", "unpublish_memory"
    )
  end

  it "marks the admin audit tool for central coworker exclusion" do
    admin_chat = ChatSession.create!(user: bootstrap_admin, repository: Factories.repository(user: bootstrap_admin))

    definitions = described_class.tool_definitions(tier: :essential, chat_session: admin_chat)
    audit = definitions.find { |definition| definition.fetch(:name) == "admin_read_memory_audit_history" }

    expect(audit).to include(admin_only: true)
    expect(Mcp::CoworkerToolExposure.plugin_definition?(audit)).to be(false)
  end

  it "marks inherited memory writes as mutations for canonical permission gating" do
    definitions = %i[essential deferred].flat_map do |tier|
      described_class.tool_definitions(tier: tier, chat_session: chat_session)
    end.index_by { |definition| definition.fetch(:name) }

    expect(definitions.values_at("write_memory", "delete_memory", "publish_memory", "unpublish_memory"))
      .to all(include(mutation: true))
    expect(definitions.values_at("read_memory", "search_memories", "list_memories"))
      .to all(include(mutation: false))
  end

  it "classifies every non-admin ordinary memory chat tool in the coworker catalog" do
    allow(McpToolContext).to receive(:from_chat_session).with(chat_session).and_return(
      instance_double(McpToolContext, role: AgentRole::COWORKER_CHAT)
    )
    expected = AgentMemory::McpToolSet::CHAT_TOOL_CLASSES.values.flatten.map(&:tool_name)

    descriptors = Mcp::CoworkerToolCatalog.all(chat_session: chat_session)
      .select { |descriptor| expected.include?(descriptor.tool_name) }

    expect(descriptors.map(&:tool_name)).to contain_exactly(*expected)
    expect(descriptors).to all(have_attributes(availability_state: :available))
  end
end
