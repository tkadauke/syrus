require "rails_helper"

RSpec.describe Mcp::Tools::ListChatsTool do
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
    hidden = ChatSession.create!(user: user, title: "Hidden", hidden_at: Time.current, updated_at: Time.current)
    ChatSession.create!(user: Factories.user, title: "Other user's chat", updated_at: Time.current)

    add_message(older)
    add_message(older, role: "assistant", text: "world")
    add_message(newer)
    add_message(hidden)
    chat_session.touch(time: 3.hours.ago)

    response = call_tool
    payload = response_payload(response)
    chats = payload.fetch(:chats)

    expect(response[:result][:isError]).to be_falsey
    expect(chats.map { |chat| chat[:id] }).to eq([ newer.id, older.id, chat_session.id ])
    expect(chats.map { |chat| chat[:id] }).not_to include(hidden.id)
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
    expect(payload.fetch(:pagination)).to include(
      page: 1,
      per_page: 20,
      total_count: 3,
      total_pages: 1,
      has_next_page: false
    )
  end

  it "paginates sessions by most recently updated first" do
    chat_session.touch(time: 1.day.ago)

    25.times do |i|
      ChatSession.create!(user: user, title: "Chat #{i}", updated_at: i.minutes.ago)
    end

    first_page = response_payload(call_tool)
    second_page = response_payload(call_tool(page: 2, per_page: 10))

    expect(first_page.fetch(:chats).size).to eq(20)
    expect(first_page.fetch(:chats).map { |chat| chat[:title] }).to eq((0..19).map { |i| "Chat #{i}" })
    expect(first_page.fetch(:chats).map { |chat| chat[:id] }).not_to include(chat_session.id)
    expect(first_page.fetch(:pagination)).to include(
      page: 1,
      per_page: 20,
      total_count: 26,
      total_pages: 2,
      has_next_page: true
    )

    expect(second_page.fetch(:chats).map { |chat| chat[:title] }).to eq((10..19).map { |i| "Chat #{i}" })
    expect(second_page.fetch(:pagination)).to include(
      page: 2,
      per_page: 10,
      total_count: 26,
      total_pages: 3,
      has_next_page: true
    )
  end

  it "normalizes pagination inputs" do
    2.times do |i|
      ChatSession.create!(user: user, title: "Chat #{i}", updated_at: i.minutes.ago)
    end

    payload = response_payload(call_tool(page: 0, per_page: 200))

    expect(payload.fetch(:chats).size).to eq(3)
    expect(payload.fetch(:pagination)).to include(
      page: 1,
      per_page: 100,
      total_count: 3,
      total_pages: 1,
      has_next_page: false
    )
  end
end
