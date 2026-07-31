require "rails_helper"

RSpec.describe "Mcp::Tools pinned context tools" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository) }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        Mcp::Tools::UpdatePinnedContextTool,
        Mcp::Tools::RemovePinnedContextTool
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

  it "updates the chat pinned context and broadcasts the header" do
    expect(chat_session).to receive(:broadcast_header).at_least(:once).and_call_original

    response = call_tool("update_pinned_context", content: "Keep OAuth callback state in mind.")

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to include(
      pinned_context: "Keep OAuth callback state in mind.",
      message: "Pinned context updated."
    )
    expect(chat_session.reload.pinned_context).to eq("Keep OAuth callback state in mind.")
  end

  it "rejects blank pinned context" do
    response = call_tool("update_pinned_context", content: " ")

    expect(response.dig(:result, :isError)).to be true
    expect(response.dig(:result, :content, 0, :text)).to include("content is required")
    expect(chat_session.reload.pinned_context).to be_nil
  end

  it "removes the chat pinned context and broadcasts the header" do
    chat_session.update!(pinned_context: "Temporary context")
    expect(chat_session).to receive(:broadcast_header).at_least(:once).and_call_original

    response = call_tool("remove_pinned_context")

    expect(response.dig(:result, :isError)).to be_falsey
    expect(payload(response)).to include(
      pinned_context: nil,
      message: "Pinned context removed."
    )
    expect(chat_session.reload.pinned_context).to be_nil
  end
end
