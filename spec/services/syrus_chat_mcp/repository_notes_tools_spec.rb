require "rails_helper"

RSpec.describe "SyrusChatMcp repository note tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        SyrusChatMcp::ReadRepoNotesTool,
        SyrusChatMcp::AddRepoNoteTool,
        SyrusChatMcp::RemoveRepoNoteTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments = {})
    raw = server.handle_json({
      jsonrpc: "2.0",
      id: 1,
      method: "tools/call",
      params: { name: name, arguments: arguments }
    }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.dig(:result, :content, 0, :text), symbolize_names: true)
  end

  it "reads active notes for the chat repository" do
    note = repository.repository_notes.create!(body: "Prefer Codex for this repo.", author: "operator")
    repository.repository_notes.create!(body: "Gone.", author: "agent", removed_at: Time.current)

    response = call_tool("read_repo_notes")

    expect(payload(response)[:notes]).to contain_exactly(
      include(id: note.id, body: "Prefer Codex for this repo.", author: "operator")
    )
  end

  it "roundtrips an agent-requested add through pending action confirmation" do
    response = call_tool("add_repo_note", body: "CI lives in .github/workflows.")
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_action_id])

    expect(pending_action).to be_pending
    expect(repository.repository_notes.count).to eq(0)

    expect {
      pending_action.confirm!
    }.to change { repository.repository_notes.active.count }.by(1)

    read_response = call_tool("read_repo_notes")
    expect(payload(read_response)[:notes]).to contain_exactly(
      include(body: "CI lives in .github/workflows.", author: "agent")
    )
  end

  it "roundtrips an agent-requested removal through pending action confirmation" do
    note = repository.repository_notes.create!(body: "Temporary fact.", author: "operator")

    response = call_tool("remove_repo_note", id: note.id)
    pending_action = chat_session.pending_actions.find(payload(response)[:pending_action_id])

    expect {
      pending_action.confirm!
    }.to change { repository.repository_notes.active.count }.from(1).to(0)
    expect(note.reload).to be_removed
  end

  it "rejects removal for notes outside the chat repository" do
    other = Factories.repository(user: user)
    note = other.repository_notes.create!(body: "Not yours.", author: "operator")

    response = call_tool("remove_repo_note", id: note.id)

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("unknown active repository note id")
  end
end
