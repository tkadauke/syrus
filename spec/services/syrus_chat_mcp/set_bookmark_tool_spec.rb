require "rails_helper"

RSpec.describe Mcp::Tools::SetBookmarkTool do
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

  def jsonrpc(server, method, id: 1, params: {})
    raw = server.handle_json({ jsonrpc: "2.0", id: id, method: method, params: params }.to_json)
    raw && JSON.parse(raw, symbolize_names: true)
  end

  def call_tool(arguments)
    jsonrpc(server, "tools/call", params: { name: "set_bookmark", arguments: arguments })
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  it "creates a bookmark on the latest chat message" do
    earlier = chat_session.messages.create!(role: "user", content: { "text" => "Start with aqueducts." })
    latest = chat_session.messages.create!(role: "assistant", content: { "text" => "Now temples." })

    response = call_tool(label: "Temple plan", kind: "topic")

    bookmark = latest.bookmarks.sole
    expect(response[:result][:isError]).to be_falsey
    expect(response_payload(response)).to include(
      id: bookmark.id,
      label: "Temple plan",
      kind: "topic",
      message_id: latest.id,
      anchor: "message-#{latest.id}"
    )
    expect(earlier.bookmarks).to be_empty
  end

  it "supports epic origin bookmarks" do
    message = chat_session.messages.create!(role: "assistant", content: { "text" => "An epic begins." })

    response = call_tool(label: "Forum rebuild", kind: "epic_origin")

    expect(response[:result][:isError]).to be_falsey
    expect(message.bookmarks.sole).to be_epic_origin
  end

  it "returns a tool error when the chat has no messages" do
    response = call_tool(label: "Nothing yet", kind: "topic")

    expect(response[:result][:isError]).to be(true)
    expect(response[:result][:content].first[:text]).to match(/empty chat/)
    expect(chat_session.bookmarks).to be_empty
  end

  it "rejects invalid bookmark kinds" do
    chat_session.messages.create!(role: "assistant", content: { "text" => "Salve" })

    response = call_tool(label: "Portent", kind: "omen")

    expect(response[:error]).to be_present
    expect(response[:error][:code]).to eq(-32602)
    expect(response[:error][:data]).to match(/kind/)
    expect(chat_session.bookmarks).to be_empty
  end
end
