require "rails_helper"

RSpec.describe SyrusChatMcp::RenameChatTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, title: "Old title") }

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
    jsonrpc(server, "tools/call", params: { name: "rename_chat", arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "renames the current chat session" do
    response = call_tool(name: "Release planning")

    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(
      session_id: chat_session.id,
      title: "Release planning"
    )
    expect(chat_session.reload.title).to eq("Release planning")
  end

  it "trims the provided name" do
    response = call_tool(name: "  Weekly triage  ")

    expect(response[:result][:isError]).to be_falsey
    expect(chat_session.reload.title).to eq("Weekly triage")
  end

  it "rejects blank names" do
    response = call_tool(name: "  ")

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/name is required/)
    expect(chat_session.reload.title).to eq("Old title")
  end

  it "rejects names over the title length limit" do
    response = call_tool(name: "a" * (ChatSession::TITLE_MAX_LENGTH + 1))

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/#{ChatSession::TITLE_MAX_LENGTH} characters or fewer/)
    expect(chat_session.reload.title).to eq("Old title")
  end
end
