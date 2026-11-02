require "rails_helper"

RSpec.describe Mcp::Tools::DiscoverCoworkerCapabilitiesTool do
  let(:user) { Factories.user }
  let(:chat_session) { ChatSession.create!(user: user) }

  def payload(response)
    JSON.parse(response.content.first[:text], symbolize_names: true)
  end

  it "rejects non-coworker roles" do
    expect(payload(described_class.call(server_context: { chat_session: chat_session }))).to eq(error: "not_authorized")
  end

  it "passes filtering options through and returns the documented state vocabulary" do
    context = McpToolContext.new(surface: :chat, role: AgentRole::COWORKER_CHAT, user: user)
    allow(McpToolContext).to receive(:from_server_context).and_return(context)
    discovery = instance_double(Permissions::CoworkerCapabilityDiscovery)
    result = Permissions::CoworkerCapabilityDiscovery::Result.new(
      capability: "example.records", operations: [ "example.records/read@v1" ],
      required_scope: { type: :none }, effective_policy: "ask", state: "requestable",
      lock_reason: "capability_not_granted"
    )
    allow(Permissions::CoworkerCapabilityDiscovery).to receive(:new).and_return(discovery)
    allow(discovery).to receive(:call).with(query: "ledger", include_non_requestable: true).and_return([ result ])

    body = payload(described_class.call(
      server_context: { chat_session: chat_session }, query: "ledger", include_non_requestable: true
    ))

    expect(body.fetch(:capabilities).sole).to include(capability: "example.records", state: "requestable")
    expect(body.fetch(:states)).to eq(%w[available requestable prohibited plugin_disabled resource_unconfigured unavailable])
  end
end
