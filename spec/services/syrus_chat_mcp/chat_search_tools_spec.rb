require "rails_helper"

RSpec.describe "Mcp::Tools chat search tools" do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repository) { Factories.repository(user: user, name: "widgets") }
  let(:other_repository) { Factories.repository(user: other_user, name: "other-widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, title: "Current chat") }
  let(:other_user_chat) { ChatSession.create!(user: other_user, repository: other_repository, title: "Other user chat") }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  def server
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        Mcp::Tools::SearchChatsTool,
        Mcp::Tools::ReadChatMessagesTool
      ],
      server_context: { chat_session: chat_session }
    )
  end

  def call_tool(name, arguments)
    raw = server.handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json)
    JSON.parse(raw, symbolize_names: true)
  end

  def response_payload(response)
    JSON.parse(response.fetch(:result).fetch(:content).first.fetch(:text), symbolize_names: true)
  end

  describe "search_chats" do
    it "returns ranked results scoped to the current user" do
      weaker = message(chat_session, role: "assistant", text: "needle deployment")
      stronger = message(chat_session, role: "user", text: "needle needle needle deployment")
      other = message(other_user_chat, role: "user", text: "needle needle needle deployment")
      [ weaker, stronger, other ].each { |chat_message| ChatMessageSearchIndex.insert(chat_message) }

      response = call_tool("search_chats", query: "needle")
      results = response_payload(response).fetch(:results)

      expect(response[:result][:isError]).to be_falsey
      expect(results.map { |result| result[:chat_session_id] }).to eq([ chat_session.id, chat_session.id ])
      expect(results.map { |result| result[:role] }).to eq(%w[user assistant])
      expect(results.first).to include(
        chat_title: "Current chat",
        snippet: a_string_including("<b>needle</b>"),
        created_at: stronger.created_at.iso8601
      )
    end

    it "uses the repository fallback title when a chat has no title" do
      untitled_chat = ChatSession.create!(user: user, repository: repository)
      indexed_message = message(untitled_chat, text: "fallback-title lookup")
      ChatMessageSearchIndex.insert(indexed_message)

      response = call_tool("search_chats", query: "fallback")
      result = response_payload(response).fetch(:results).first

      expect(result[:chat_title]).to eq("widgets")
    end

    it "returns an empty successful response when no messages match" do
      response = call_tool("search_chats", query: "absent")
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload).to eq(results: [], message: "No matching messages found.")
    end

    it "returns an invalid response for blank queries" do
      response = call_tool("search_chats", query: " ")

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("query is required")
    end

    it "respects limit and caps it at 50" do
      55.times do |i|
        ChatMessageSearchIndex.insert(message(chat_session, text: "limitneedle #{i}"))
      end

      response = call_tool("search_chats", query: "limitneedle", limit: 100)

      expect(response_payload(response).fetch(:results).size).to eq(50)
    end
  end

  describe "read_chat_messages" do
    it "returns paginated messages ordered by creation time and id" do
      messages = 31.times.map { |i| message(chat_session, role: i.even? ? "user" : "assistant", text: "message #{i}") }

      response = call_tool("read_chat_messages", chat_session_id: chat_session.id, page: 2)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload[:page]).to eq(2)
      expect(payload[:total_pages]).to eq(2)
      expect(payload[:chat_title]).to eq("Current chat")
      expect(payload[:messages]).to contain_exactly(
        {
          id: messages.last.id,
          role: messages.last.role,
          content: { text: "message 30" },
          created_at: messages.last.created_at.iso8601
        }
      )
    end

    it "rejects access to another user's chat" do
      response = call_tool("read_chat_messages", chat_session_id: other_user_chat.id)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("not_authorized")
    end

    it "handles a missing chat gracefully" do
      response = call_tool("read_chat_messages", chat_session_id: ChatSession.maximum(:id).to_i + 100)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("not_authorized")
    end
  end

  def message(session, role: "user", text:)
    ChatMessage.create!(
      chat_session: session,
      role: role,
      content: { "text" => text }
    )
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_search_metadata")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(
        content,
        user_id UNINDEXED,
        chat_session_id UNINDEXED,
        chat_message_id UNINDEXED,
        role UNINDEXED,
        created_at UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
    SearchRecord.connection.execute(<<~SQL)
      CREATE TABLE chat_search_metadata (
        key TEXT PRIMARY KEY,
        value TEXT
      )
    SQL
  end
end
