require "rails_helper"

RSpec.describe SyrusChatMcp::ProposeEpicTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "propose_epic", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "creates an Epic proposal through the JSON-RPC path" do
    response = call_tool(slug: "manual-epic", title: "Manual Epic", body: "Coordinate the work.")

    proposal = chat_session.proposals.find_by!(slug: "manual-epic")
    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(id: proposal.id, slug: "manual-epic", state: "proposed")
    expect(proposal).to have_attributes(
      title: "Manual Epic",
      body: "Coordinate the work.",
      kind: "epic"
    )
    expect(chat_session.messages.last).to have_attributes(role: "assistant", proposal: proposal)
  end

  it "returns a tool error for unknown dependency slugs" do
    response = call_tool(slug: "leaf", title: "Leaf", body: "Body.", depends_on: %w[missing])

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/unknown depends_on slug/)
  end
end
