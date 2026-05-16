require "rails_helper"

RSpec.describe SyrusChatMcp::ProposeIssueTool do
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

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(arguments)
    jsonrpc(server, "tools/call", params: { name: "propose_issue", arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "creates a proposal and dependency edges via the JSON-RPC path" do
    root = ChatProposal.create!(
      chat_session: chat_session,
      slug: "root",
      title: "Root",
      body: "File first."
    )

    response = call_tool(
      slug: "leaf",
      title: "Leaf issue",
      body: "File second.",
      kind: "github_issue",
      labels: %w[bug syrus],
      depends_on: %w[root]
    )

    proposal = chat_session.proposals.find_by!(slug: "leaf")
    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(id: proposal.id, slug: "leaf", state: "proposed")
    expect(proposal).to have_attributes(
      title: "Leaf issue",
      body: "File second.",
      kind: "github_issue",
      labels: %(["bug","syrus"])
    )
    expect(proposal.dependencies).to contain_exactly(root)
    expect(chat_session.messages.last).to have_attributes(role: "assistant", proposal: proposal)
  end

  it "updates the existing proposal for the same slug" do
    original = ChatProposal.create!(
      chat_session: chat_session,
      slug: "same",
      title: "Old",
      body: "Old body.",
      labels: %(["old"])
    )

    response = call_tool(slug: "same", title: "New", body: "New body.", labels: %w[new])

    expect(response[:result][:isError]).to be_falsey
    expect(chat_session.proposals.where(slug: "same").count).to eq(1)
    expect(original.reload).to have_attributes(title: "New", body: "New body.", labels: %(["new"]), state: "proposed")
    expect(original.edited_at).to be_present
  end

  it "returns a tool error for unknown dependency slugs" do
    response = call_tool(slug: "leaf", title: "Leaf", body: "Body.", depends_on: %w[missing])

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/unknown depends_on slug/)
    expect(chat_session.proposals.find_by(slug: "leaf")).to be_nil
  end

  it "does not allow the grouped Epic proposal kind through the issue tool" do
    response = described_class.call(
      slug: "epic",
      title: "Epic",
      body: "Body.",
      kind: "epic",
      server_context: { chat_session: chat_session }
    )

    expect(response.instance_variable_get(:@error)).to be(true)
    expect(response.content.first[:text]).to match(/kind must be syrus_issue or github_issue/)
    expect(chat_session.proposals.find_by(slug: "epic")).to be_nil
  end

  it "returns a tool error when dependencies would create a cycle" do
    root = ChatProposal.create!(chat_session: chat_session, slug: "root", title: "Root", body: "Root.")
    leaf = ChatProposal.create!(chat_session: chat_session, slug: "leaf", title: "Leaf", body: "Leaf.")
    ChatProposalDependency.create!(proposal: leaf, depends_on: root)

    response = call_tool(slug: "root", title: "Root", body: "Root.", depends_on: %w[leaf])

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/cycle/)
    expect(root.reload.dependencies).to be_empty
  end

  it "rejects calls missing required arguments at the schema layer" do
    response = call_tool(slug: "missing-title")

    expect(response[:error]).to be_present
    expect(response[:error][:code]).to eq(-32602)
    expect(response[:error][:data]).to match(/Missing required arguments/)
  end
end
