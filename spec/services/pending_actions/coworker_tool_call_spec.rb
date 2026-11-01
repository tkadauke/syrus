require "rails_helper"

RSpec.describe PendingActions::CoworkerToolCall do
  let(:owner) { Factories.user }
  let(:repository) { Factories.repository(user: owner) }
  let(:chat) { ChatSession.create!(user: owner, repository:) }
  let(:coworker) do
    Coworkers::Coworker.create!(
      owner_user: owner, name: "Maya", handle: "maya", workspace_repo: repository.remote_url
    )
  end
  let(:tool) do
    Class.new(MCP::Tool) do
      tool_name "read_custom_data"
      input_schema(properties: { query: { type: "string" } }, required: %w[query])
    end
  end
  let(:descriptor) do
    Permissions::CapabilityDescriptorAdapter.for_registry_entry(
      tool_name: "read_custom_data", capability: "custom.read", mutation: false,
      required_roles: [ AgentRole::COWORKER_CHAT ]
    )
  end
  let(:catalog_descriptor) do
    Mcp::CoworkerToolCatalog::Descriptor.new(
      tool_name: "read_custom_data", capability: "custom.read", ungated: false,
      tier: :essential, tool:, provider: nil
    )
  end
  let(:context) do
    McpToolContext.new(
      surface: :chat, role: AgentRole::COWORKER_CHAT, user: owner,
      repository:, chat_session: chat, agent_actor: coworker
    )
  end
  let(:request) do
    Permissions::CoworkerAuthorizationRequest.new(
      context:, descriptor:, arguments: { "query" => "customers" },
      action: "coworker_tool_call",
      payload: { "tool_name" => "read_custom_data", "arguments" => { "query" => "customers" } }
    ).call.request
  end

  before do
    Coworkers::Chat.create!(coworker:, chat_session: chat, role: "main")
    allow(Mcp::CoworkerToolCatalog).to receive(:resolve).and_return(catalog_descriptor)
    entry = Struct.new(:tool, :descriptor).new(tool, descriptor)
    allow(McpToolRegistry).to receive(:entries).with(surface: :coworker).and_return([ entry ])
  end

  it "refuses execution until every authorization item is approved" do
    expect { described_class.new(request).authorize_execution! }
      .to raise_error(ArgumentError, /prerequisites are not approved/)
  end

  it "accepts only the exact fingerprinted invocation after all items are approved" do
    request.authorization_items.each do |item|
      duration = item.kind == "operation" ? "invocation" : nil
      item.decide!("approved", principal: owner, duration:)
    end

    expect { described_class.new(request).authorize_execution! }.not_to raise_error

    request.update!(payload: request.payload.merge("arguments" => { "query" => "payments" }))
    expect { described_class.new(request).authorize_execution! }
      .to raise_error(ArgumentError, /no longer matches/)
  end
end
