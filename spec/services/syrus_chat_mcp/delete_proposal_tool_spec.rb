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

  it "discards child proposals when deleting an epic bundle" do
    parent = ChatProposal.create!(chat_session: chat_session, slug: "epic-draft", kind: "epic", title: "My Epic", body: "Epic.")
    child1 = ChatProposal.create!(chat_session: chat_session, slug: "job-draft-1", title: "Job 1", body: "Job 1.", parent_proposal: parent)
    child2 = ChatProposal.create!(chat_session: chat_session, slug: "job-draft-2", title: "Job 2", body: "Job 2.", parent_proposal: parent)

    response = call_tool("epic-draft")

    expect(response[:result][:isError]).to be_falsey
    expect(parent.reload).to be_withdrawn
    expect(child1.reload).to be_withdrawn
    expect(child2.reload).to be_withdrawn
    cascade_slugs = response_payload(response)[:cascade].map { |p| p[:slug] }
    expect(cascade_slugs).to include("job-draft-1", "job-draft-2")
  end

  it "does not discard already-rejected child proposals when deleting an epic bundle" do
    parent = ChatProposal.create!(chat_session: chat_session, slug: "epic-draft", kind: "epic", title: "My Epic", body: "Epic.")
    proposed_child = ChatProposal.create!(chat_session: chat_session, slug: "job-draft-1", title: "Job 1", body: "Job 1.", parent_proposal: parent)
    rejected_child = ChatProposal.create!(chat_session: chat_session, slug: "job-draft-2", title: "Job 2", body: "Job 2.", parent_proposal: parent, state: "rejected")

    response = call_tool("epic-draft")

    expect(response[:result][:isError]).to be_falsey
    expect(parent.reload).to be_withdrawn
    expect(proposed_child.reload).to be_withdrawn
    expect(rejected_child.reload).to be_rejected
  end

  it "broadcasts an update_proposal event for the withdrawn proposal and each cascade dependent" do
    root = ChatProposal.create!(chat_session: chat_session, slug: "root", title: "Root", body: "Root.")
    dependent = ChatProposal.create!(chat_session: chat_session, slug: "dep", title: "Dep", body: "Dep.")
    ChatProposalDependency.create!(proposal: dependent, depends_on: root)

    allow(AppEvents).to receive(:broadcast)
    call_tool("root")

    expect(AppEvents).to have_received(:broadcast).with(
      user: user,
      type: "updated",
      resource: "chat",
      id: chat_session.id,
      changed: [ "proposal" ],
      payload: { action: "update_proposal", proposal_id: root.id }
    )
    expect(AppEvents).to have_received(:broadcast).with(
      user: user,
      type: "updated",
      resource: "chat",
      id: chat_session.id,
      changed: [ "proposal" ],
      payload: { action: "update_proposal", proposal_id: dependent.id }
    )
  end

  it "returns a tool error for an unknown slug" do
    response = call_tool("missing")

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/unknown proposal slug/)
  end
end
