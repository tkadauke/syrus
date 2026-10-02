require "rails_helper"

RSpec.describe "chat pinning MCP tools" do
  let!(:_bootstrap_admin) { Factories.user(admin: true) }
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, title: "Current chat") }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ Mcp::Tools::PinChatTool, Mcp::Tools::UnpinChatTool ],
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

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "pins the current chat by default" do
    response = call_tool("pin_chat")
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload).to include(
      session_id: chat_session.id,
      title: "Current chat",
      pinned: true,
      message: "Chat pinned."
    )
    expect(chat_session.reload.pinned?).to be(true)
  end

  it "unpins the current chat by default" do
    chat_session.update!(pinned: true)

    response = call_tool("unpin_chat")
    payload = response_payload(response)

    expect(response[:result][:isError]).to be_falsey
    expect(payload).to include(
      session_id: chat_session.id,
      pinned: false,
      message: "Chat unpinned."
    )
    expect(chat_session.reload.pinned?).to be(false)
  end

  it "pins and unpins an explicit accessible chat session" do
    target = ChatSession.create!(user: user, title: "Target chat")

    pin_response = call_tool("pin_chat", chat_session_id: target.id)
    unpin_response = call_tool("unpin_chat", chat_session_id: target.id)

    expect(pin_response[:result][:isError]).to be_falsey
    expect(response_payload(pin_response)).to include(session_id: target.id, title: "Target chat", pinned: true)
    expect(unpin_response[:result][:isError]).to be_falsey
    expect(response_payload(unpin_response)).to include(session_id: target.id, title: "Target chat", pinned: false)
    expect(target.reload.pinned?).to be(false)
    expect(chat_session.reload.pinned?).to be(false)
  end

  it "is idempotent for already-pinned and already-unpinned chats" do
    chat_session.update!(pinned: true)

    pinned_response = call_tool("pin_chat")
    expect(pinned_response[:result][:isError]).to be_falsey
    expect(response_payload(pinned_response)).to include(pinned: true, message: "Chat pinned.")

    chat_session.update!(pinned: false)
    unpinned_response = call_tool("unpin_chat")
    expect(unpinned_response[:result][:isError]).to be_falsey
    expect(response_payload(unpinned_response)).to include(pinned: false, message: "Chat unpinned.")
  end

  it "returns validation errors for invalid explicit ids" do
    response = call_tool("pin_chat", chat_session_id: -1)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("chat_session_id must be a positive integer")
    expect(chat_session.reload.pinned?).to be(false)
  end

  it "does not disclose or mutate missing chats" do
    response = call_tool("pin_chat", chat_session_id: ChatSession.maximum(:id).to_i + 100)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("not_authorized")
  end

  it "denies hidden and deleted chat sessions" do
    hidden = ChatSession.create!(user: user, title: "Hidden", hidden_at: Time.current)
    deleted = ChatSession.create!(user: user, title: "Deleted")
    deleted.soft_delete_by!(user)

    hidden_response = call_tool("pin_chat", chat_session_id: hidden.id)
    deleted_response = call_tool("pin_chat", chat_session_id: deleted.id)

    expect(hidden_response[:result][:isError]).to be(true)
    expect(hidden_response[:result][:content].first[:text]).to include("not_authorized")
    expect(deleted_response[:result][:isError]).to be(true)
    expect(deleted_response[:result][:content].first[:text]).to include("not_authorized")
    expect(hidden.reload.pinned?).to be(false)
    expect(deleted.reload.pinned?).to be(false)
  end

  it "denies another user's chat session" do
    other_user = Factories.user
    other_chat = ChatSession.create!(user: other_user, title: "Other chat")

    response = call_tool("pin_chat", chat_session_id: other_chat.id)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("not_authorized")
    expect(other_chat.reload.pinned?).to be(false)
  end

  it "respects restricted chat-session MCP contexts" do
    target = ChatSession.create!(user: user, title: "Restricted target")
    restricted_context = McpToolContext.new(
      surface: :chat,
      role: AgentRole::CHAT_PLANNER,
      user: user,
      allowed_chat_session_ids: [ chat_session.id ]
    )
    allow(McpToolContext).to receive(:from_server_context).and_return(restricted_context)

    response = call_tool("pin_chat", chat_session_id: target.id)

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to include("not_authorized")
    expect(target.reload.pinned?).to be(false)
  end
end
