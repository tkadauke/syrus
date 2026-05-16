require "rails_helper"

RSpec.describe SyrusChatMcp::ListProposalsTool do
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

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "lists every proposal with content, state, labels, and dependencies through JSON-RPC" do
    root = ChatProposal.create!(
      chat_session: chat_session,
      slug: "root",
      title: "Root",
      body: "Root body.",
      labels: %(["syrus"])
    )
    leaf = ChatProposal.create!(
      chat_session: chat_session,
      slug: "leaf",
      title: "Leaf",
      body: "Leaf body.",
      kind: "github_issue",
      state: "withdrawn"
    )
    ChatProposalDependency.create!(proposal: leaf, depends_on: root)

    response = jsonrpc("tools/call", params: { name: "list_proposals", arguments: {} })

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)[:proposals]).to eq([
      {
        id: root.id,
        slug: "root",
        title: "Root",
        body: "Root body.",
        kind: "syrus_issue",
        state: "proposed",
        labels: %w[syrus],
        dependencies: [],
        materialized: nil
      },
      {
        id: leaf.id,
        slug: "leaf",
        title: "Leaf",
        body: "Leaf body.",
        kind: "github_issue",
        state: "withdrawn",
        labels: [],
        dependencies: %w[root],
        materialized: nil
      }
    ])
  end
end
