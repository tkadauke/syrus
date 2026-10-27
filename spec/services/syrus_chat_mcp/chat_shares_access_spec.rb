require "rails_helper"

RSpec.describe "chat MCP share access" do
  let(:owner) { Factories.user }
  let(:recipient) { Factories.user }
  let(:outsider) { Factories.user }
  let(:shared_chat) { ChatSession.create!(user: owner, title: "Shared MCP chat") }

  def call_tool(user, tool, arguments = {})
    context_chat = ChatSession.create!(user: user, title: "Tool context")
    server = MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ Mcp::Tools::ListChatsTool, Mcp::Tools::ReadChatMessagesTool ],
      server_context: { chat_session: context_chat }
    )
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: tool, arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "shows a shared chat in list_chats and read_chat_messages only to its recipient" do
    message = shared_chat.messages.create!(role: "assistant", content: { "text" => "shared tool result" })
    ChatShare.create!(chat_session: shared_chat, target: recipient, shared_by_user: owner)

    listed_ids = payload(call_tool(recipient, "list_chats")).fetch(:chats).pluck(:id)
    expect(listed_ids).to include(shared_chat.id)
    read = call_tool(recipient, "read_chat_messages", chat_session_id: shared_chat.id)
    expect(payload(read).fetch(:messages).pluck(:id)).to include(message.id)

    outsider_ids = payload(call_tool(outsider, "list_chats")).fetch(:chats).pluck(:id)
    expect(outsider_ids).not_to include(shared_chat.id)
    denied = call_tool(outsider, "read_chat_messages", chat_session_id: shared_chat.id)
    expect(denied.dig(:result, :isError)).to be(true)
  end
end
