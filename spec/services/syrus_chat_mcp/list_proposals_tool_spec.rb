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
        repository: repository.slug,
        target_epic: nil,
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
        repository: repository.slug,
        target_epic: nil,
        materialized: {
          kind: "rejected",
          reason: "withdrawn"
        }
      }
    ])
  end

  it "lists materialized details for confirmed job and epic proposals" do
    job = Factories.job_record(user: user, repository: repository, issue_title: "Add inspection tools", state: "open")
    epic = Factories.epic(user: user, repository: repository, title: "Chat-driven job feedback loop")
    child_job = Factories.job_record(user: user, repository: repository, issue_title: "Add trigger", state: "queued")
    job_proposal = chat_session.proposals.create!(
      repository: repository,
      job: job,
      kind: "job",
      state: "confirmed",
      slug: "inspection-tools",
      title: "Add inspection tools",
      body: "Inspect more."
    )
    epic_proposal = chat_session.proposals.create!(
      repository: repository,
      epic: epic,
      kind: "epic",
      state: "confirmed",
      slug: "feedback-loop",
      title: "Chat-driven job feedback loop",
      body: "Bundle the work."
    )
    chat_session.proposals.create!(
      repository: repository,
      parent_proposal: epic_proposal,
      job: child_job,
      kind: "job",
      state: "confirmed",
      slug: "add-trigger",
      title: "Add trigger",
      body: "Trigger it."
    )

    response = jsonrpc("tools/call", params: { name: "list_proposals", arguments: {} })

    proposals = response_payload(response).fetch(:proposals)
    expect(proposals.find { |proposal| proposal[:id] == job_proposal.id }.fetch(:materialized)).to eq(
      kind: "job",
      job_id: job.id,
      job_title: "Add inspection tools",
      job_state: "open"
    )
    expect(proposals.find { |proposal| proposal[:id] == epic_proposal.id }.fetch(:materialized)).to eq(
      kind: "epic",
      epic_id: epic.id,
      epic_title: "Chat-driven job feedback loop",
      child_jobs: [
        { job_id: child_job.id, title: "Add trigger" }
      ]
    )
  end
end
