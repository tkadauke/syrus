require "rails_helper"

RSpec.describe SyrusChatMcp::ProposeEpicTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
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

  it "creates an Epic-only proposal card" do
    response = call_tool(title: "Codify the marble agenda", description: "Give the backlog a Senate chamber.")

    proposal = chat_session.proposals.find_by!(title: "Codify the marble agenda")
    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(id: proposal.id, kind: "epic", repository: repository.slug)
    expect(proposal).to have_attributes(
      kind: "epic",
      repository: repository,
      body: "Give the backlog a Senate chamber."
    )
    expect(proposal.job).to be_nil
    expect(proposal.epic).to be_nil
    expect(chat_session.messages.last).to have_attributes(role: "assistant", proposal: proposal)
  end

  it "uses the first attached repo token when provided" do
    other_repo = Factories.repository(user: user, owner: "acme", name: "scrolls")

    response = call_tool(
      title: "Inventory the scrolls",
      description: "Find the scroll shelf.",
      attached_repos: [ other_repo.slug ]
    )

    expect(response[:result][:isError]).to be_falsey
    expect(chat_session.proposals.last.repository).to eq(other_repo)
  end

  it "persists existing Job dependencies" do
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 7)

    response = call_tool(
      title: "Blocked Epic",
      description: "Wait for the direct Job first.",
      depends_on_job_ids: [ prerequisite.id ]
    )

    proposal = chat_session.proposals.find_by!(title: "Blocked Epic")
    expect(response[:result][:isError]).to be_falsey
    expect(proposal.depends_on_job_ids).to eq([ prerequisite.id ])
  end

  it "persists Epic proposal slug dependencies" do
    prerequisite = chat_session.proposals.create!(
      repository: repository,
      slug: "foundation-epic",
      title: "Foundation Epic",
      body: "Do this first.",
      kind: "epic"
    )

    response = call_tool(
      title: "Blocked Epic",
      description: "Wait for another proposed Epic.",
      depends_on_proposal_slugs: [ prerequisite.slug ]
    )

    proposal = chat_session.proposals.find_by!(title: "Blocked Epic")
    expect(response[:result][:isError]).to be_falsey
    expect(proposal.dependencies).to contain_exactly(prerequisite)
    expect(proposal.epic_dependency_tokens).to eq([ prerequisite.slug ])
    expect(response_payload(response)).to include(depends_on_proposal_slugs: [ prerequisite.slug ])
  end

  it "rejects unknown Job dependency IDs" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    foreign_job = Factories.job_record(user: other_user, repository: other_repo)

    response = call_tool(title: "Invalid", description: "Body.", depends_on_job_ids: [ foreign_job.id ])

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("unknown depends_on_job_ids")
  end

  it "returns a tool error for unknown dependency slugs" do
    response = call_tool(title: "Leaf", description: "Body.", depends_on: %w[missing])

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/unknown depends_on_proposal_slugs/)
  end
end
