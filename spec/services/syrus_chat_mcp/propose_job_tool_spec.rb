require "rails_helper"

RSpec.describe SyrusChatMcp::ProposeJobTool do
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
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "propose_job", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "creates a Job proposal targeting an existing Epic" do
    epic = Factories.epic(user: user, repository: repository, title: "Forum renovation")

    response = call_tool(
      repo: repository.slug,
      epic_id: epic.id,
      title: "Install carved labels",
      description: "Every marble drawer deserves a label."
    )

    proposal = chat_session.proposals.find_by!(title: "Install carved labels")
    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(id: proposal.id, kind: "job")
    expect(response_payload(response)[:target_epic]).to include(id: epic.id, label: epic.display_number)
    expect(proposal).to have_attributes(
      kind: "job",
      repository: repository,
      target_epic: epic
    )
    expect(chat_session.messages.last).to have_attributes(role: "assistant", proposal: proposal)
  end

  it "creates an epicless Job proposal with dependency edges" do
    root = chat_session.proposals.create!(
      repository: repository,
      slug: "root",
      title: "Root",
      body: "Start here.",
      kind: "job"
    )

    response = call_tool(
      repo: repository.name,
      title: "Follow-up edict",
      description: "Continue in an orderly fashion.",
      depends_on: [ "root" ]
    )

    proposal = chat_session.proposals.find_by!(title: "Follow-up edict")
    expect(response[:result][:isError]).to be_falsey
    expect(proposal.target_epic).to be_nil
    expect(proposal.dependencies).to contain_exactly(root)
  end

  it "persists existing Epic dependencies" do
    prerequisite = Factories.epic(user: user, repository: repository)

    response = call_tool(
      repo: repository.slug,
      title: "Wait for the Epic",
      description: "Do this after the wider effort lands.",
      depends_on_epic_ids: [ prerequisite.id ]
    )

    proposal = chat_session.proposals.find_by!(title: "Wait for the Epic")
    expect(response[:result][:isError]).to be_falsey
    expect(proposal.depends_on_epic_ids).to eq([ prerequisite.id ])
  end

  it "persists existing Job dependencies and returns them in the proposal payload" do
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 7)

    response = call_tool(
      repo: repository.slug,
      title: "Wait for the Job",
      description: "Do this after the prerequisite Job lands.",
      depends_on_job_ids: [ prerequisite.id ]
    )

    proposal = chat_session.proposals.find_by!(title: "Wait for the Job")
    payload = response_payload(response)
    expect(response[:result][:isError]).to be_falsey
    expect(proposal.depends_on_job_ids).to eq([ prerequisite.id ])
    expect(payload[:depends_on_job_ids]).to eq([ prerequisite.id ])
  end

  it "rejects unknown Epic dependency IDs" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    foreign_epic = Factories.epic(user: other_user, repository: other_repo)

    response = call_tool(
      repo: repository.slug,
      title: "Wrong owner",
      description: "This should not pass.",
      depends_on_epic_ids: [ foreign_epic.id, 123_456 ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("unknown depends_on_epic_ids")
    expect(chat_session.proposals.find_by(title: "Wrong owner")).to be_nil
  end

  it "rejects unknown Job dependency IDs" do
    other_user = Factories.user
    other_repo = Factories.repository(user: other_user)
    foreign_job = Factories.job_record(user: other_user, repository: other_repo)

    response = call_tool(
      repo: repository.slug,
      title: "Wrong upstream",
      description: "This should not pass.",
      depends_on_job_ids: [ foreign_job.id, 123_456 ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("unknown depends_on_job_ids")
    expect(chat_session.proposals.find_by(title: "Wrong upstream")).to be_nil
  end

  it "rejects an Epic from another repository" do
    other_repo = Factories.repository(user: user, owner: "acme", name: "scrolls")
    epic = Factories.epic(user: user, repository: other_repo)

    response = call_tool(
      repo: repository.slug,
      epic_id: epic.id,
      title: "Misfile the edict",
      description: "This should not pass."
    )

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("epic_id was not found")
    expect(chat_session.proposals.find_by(title: "Misfile the edict")).to be_nil
  end
end
