require "rails_helper"

RSpec.describe SyrusChatMcp::ReadEpicTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "roads") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "read_epic", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def tool_payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "reads an attached Epic and its child Jobs" do
    epic = Factories.epic(
      user: user,
      repository: repository,
      title: "Pave the Appian Way again",
      description: "The stones have opinions. The operator asked for fewer of them."
    )
    upstream = Factories.job_record(
      user: user,
      repository: repository,
      issue_title: "Survey the old stones",
      state: "closed"
    )
    child = Factories.job_record(
      user: user,
      repository: repository,
      epic: epic,
      issue_title: "Set the new stones",
      issue_body: "Keep the cart wheels from litigating every mile.",
      state: "queued"
    )
    JobDependency.create!(job: child, depends_on_job: upstream, source: "manual")
    chat_session.chat_attachments.create!(attachable: epic)

    payload = tool_payload(call_tool(id: epic.id))

    expect(payload[:epic]).to include(
      id: epic.id,
      number: epic.number,
      display_number: epic.display_number,
      title: "Pave the Appian Way again",
      state: epic.reload.state,
      repository: "acme/roads"
    )
    expect(payload[:epic][:description]).to include(
      text: "The stones have opinions. The operator asked for fewer of them.",
      truncated: false
    )
    expect(payload[:child_jobs]).to contain_exactly(
      include(
        id: child.id,
        issue_title: "Set the new stones",
        issue_body: include(text: "Keep the cart wheels from litigating every mile."),
        depends_on_jobs: [
          include(id: upstream.id, issue_title: "Survey the old stones")
        ]
      )
    )
  end

  it "rejects Epics that are not attached to the chat session" do
    epic = Factories.epic(user: user, repository: repository)

    response = call_tool(id: epic.id)

    expect(response.dig(:result, :isError)).to eq(true)
    expect(response.dig(:result, :content, 0, :text)).to include("epic not found in this chat session's attachments")
  end
end
