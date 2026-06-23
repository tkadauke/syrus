require "rails_helper"

RSpec.describe SyrusChatMcp::ListChatsTool do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user, owner: "acme", name: "widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, title: "Current chat") }

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [ described_class ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(arguments = {})
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: "list_chats", arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  def add_message(session, role: "user", text: "hello")
    ChatMessage.create!(chat_session: session, role: role, content: { text: text })
  end

  it "returns recent chats for the current user with compact navigation context" do
    older_repo = Factories.repository(user: user, owner: "acme", name: "api")
    older = ChatSession.create!(user: user, repository: older_repo, title: nil, updated_at: 2.hours.ago)
    newer = ChatSession.create!(user: user, title: "Epic #42 follow-up", updated_at: 1.hour.ago)
    ChatSession.create!(user: Factories.user, title: "Other user's chat", updated_at: Time.current)

    add_message(older)
    add_message(older, role: "assistant", text: "world")
    add_message(newer)
    chat_session.touch(time: 3.hours.ago)

    response = call_tool
    chats = response_payload(response).fetch(:chats)

    expect(response[:result][:isError]).to be_falsey
    expect(chats.map { |chat| chat[:id] }).to eq([ newer.id, older.id, chat_session.id ])
    expect(chats.first).to include(
      title: "Epic #42 follow-up",
      repository: nil,
      message_count: 1
    )
    expect(chats.second).to include(
      title: "api",
      repository: "acme/api",
      message_count: 2
    )
    expect(chats.second[:updated_at]).to be_present
  end

  it "limits results to the 20 most recently updated sessions" do
    chat_session.touch(time: 1.day.ago)

    25.times do |i|
      ChatSession.create!(user: user, title: "Chat #{i}", updated_at: i.minutes.ago)
    end

    response = call_tool
    chats = response_payload(response).fetch(:chats)

    expect(chats.size).to eq(20)
    expect(chats.map { |chat| chat[:title] }).to eq((0..19).map { |i| "Chat #{i}" })
    expect(chats.map { |chat| chat[:id] }).not_to include(chat_session.id)
  end
end
