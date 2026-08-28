require "rails_helper"

RSpec.describe Mcp::Tools::ProposeEpicTool do
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

  it "always rejects, directing the caller to propose_epic_with_jobs" do
    response = call_tool(title: "Codify the marble agenda", description: "Give the backlog a Senate chamber.")

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("propose_epic_with_jobs")
    expect(chat_session.proposals).to be_empty
  end

  it "does not create a proposal even with dependency fields provided" do
    prerequisite = Factories.job_record(user: user, repository: repository, issue_number: 7)

    response = call_tool(
      title: "Blocked Epic",
      description: "Wait for the direct Job first.",
      depends_on_job_ids: [ prerequisite.id ]
    )

    expect(response[:result][:isError]).to be(true)
    expect(chat_session.proposals).to be_empty
  end
end
