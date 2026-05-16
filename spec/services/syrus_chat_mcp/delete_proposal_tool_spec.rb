require "rails_helper"

RSpec.describe SyrusChatMcp::DeleteProposalTool do
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

  def jsonrpc(method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(slug)
    jsonrpc("tools/call", params: { name: "delete_proposal", arguments: { slug: slug } })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "discards a proposal and its downstream dependents through JSON-RPC" do
    root = ChatProposal.create!(chat_session: chat_session, slug: "root", title: "Root", body: "Root.")
    middle = ChatProposal.create!(chat_session: chat_session, slug: "middle", title: "Middle", body: "Middle.")
    leaf = ChatProposal.create!(chat_session: chat_session, slug: "leaf", title: "Leaf", body: "Leaf.")
    unrelated = ChatProposal.create!(chat_session: chat_session, slug: "other", title: "Other", body: "Other.")
    ChatProposalDependency.create!(proposal: middle, depends_on: root)
    ChatProposalDependency.create!(proposal: leaf, depends_on: middle)

    response = call_tool("root")

    expect(response[:result][:isError]).to be_falsey
    expect(root.reload).to be_withdrawn
    expect(middle.reload).to be_withdrawn
    expect(leaf.reload).to be_withdrawn
    expect(unrelated.reload).to be_pending
    expect(response_payload(response)[:cascade].map { |proposal| proposal[:slug] }).to eq(%w[middle leaf])
  end

  it "returns a tool error for an unknown slug" do
    response = call_tool("missing")

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/unknown proposal slug/)
  end
end
