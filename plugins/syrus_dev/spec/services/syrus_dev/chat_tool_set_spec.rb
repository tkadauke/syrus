require "rails_helper"

RSpec.describe SyrusDev::ChatToolSet do
  let(:owner) { Factories.user(admin: true) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner,
      name: "Maya",
      handle: "maya-syrus-dev",
      workspace_repo: "https://github.com/example/workspace.git"
    )
  end
  let(:coworker_chat) do
    ChatSession.create!(user: owner).tap do |chat|
      chat_coworker = coworker
      chat.define_singleton_method(:coworker) { chat_coworker }
    end
  end
  let(:ordinary_chat) { ChatSession.create!(user: owner) }
  let(:tool_names) { %w[read_performance_diagnostics read_syrus_logs] }

  before do
    PluginRecord.find_by!(name: "syrus_dev").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  it "registers its grant and exactly two coworker-safe tools" do
    expect(chat_tool_sets).to include(described_class)
    expect(Mcp::CoworkerToolExposure.coworker_only_exception(described_class))
      .to have_attributes(reason_code: "coworker_sanitized_surface", owner: "syrus-dev")
    expect(described_class.coworker_grants).to contain_exactly(include(
      name: "syrus_dev.read_diagnostics",
      default_policy: "confirm",
      maximum_policy: "auto",
      tools: contain_exactly(*tool_names)
    ))
    expect(described_class.tool_definitions(tier: :essential)).to all(
      include(
        coworker_safe: true,
        capability: "syrus_dev.read_diagnostics",
        capability_descriptor: be_a(Permissions::CapabilityDescriptor)
      )
    )
    expect(described_class.tool_definitions(tier: :essential).to_h { |definition|
      [ definition.fetch(:name), definition.fetch(:capability_descriptor).operation ]
    }).to eq(
      "read_performance_diagnostics" => "syrus_dev.performance/read@v1",
      "read_syrus_logs" => "syrus_dev.logs/search@v1"
    )
    expect(described_class.tool_definitions(tier: :essential).map { |definition| definition.fetch(:capability_descriptor) })
      .to all(have_attributes(
        capability: "syrus_dev.read_diagnostics@v1",
        effects: [ :confidential_read ],
        risk: :medium,
        defaults: include(AgentRole::COWORKER_CHAT => :ask, AgentRole::COWORKER => :ask)
      ))
  end

  it "advertises both tools as requestable without treating legacy grants as authority" do
    expect(advertised_plugin_tools(coworker_chat)).to contain_exactly(*tool_names)

    coworker.grants.create!(capability: "syrus_dev.read_diagnostics", approval_policy: "confirm")

    expect(advertised_plugin_tools(coworker_chat)).to contain_exactly(*tool_names)
  end

  it "does not advertise either tool to an ordinary operator chat" do
    expect(described_class.available_for?(ordinary_chat, tier: :essential)).to be(false)
    expect(Mcp::Sidecar.plugin_tools_for(ordinary_chat, tier: :essential)).not_to include(
      satisfy { |tool| tool_names.include?(McpToolRegistry.tool_name_for(tool)) }
    )
  end

  def advertised_plugin_tools(chat)
    Mcp::Sidecar.mcp_tools_for(described_class, tier: :essential, chat_session: chat, policy: :coworker)
      .map { |tool| McpToolRegistry.tool_name_for(tool) }
  end
end
