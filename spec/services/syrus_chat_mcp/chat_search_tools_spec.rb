require "rails_helper"

RSpec.describe "Mcp::Tools chat search tools" do
  # Consume the first-user admin-promotion slot so `user` below is not auto-promoted.
  let!(:_bootstrap_admin) { Factories.user(admin: true) }

  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: user, name: "widgets") }
  let(:other_repository) { Factories.repository(user: other_user, name: "other-widgets") }
  let(:admin_repository) { Factories.repository(user: admin, name: "admin-widgets") }
  let(:chat_session) { ChatSession.create!(user: user, repository: repository, title: "Current chat") }
  let(:other_user_chat) { ChatSession.create!(user: other_user, repository: other_repository, title: "Other user chat") }
  let(:admin_chat_session) { ChatSession.create!(user: admin, repository: admin_repository, title: "Admin chat") }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  def server(caller_session = chat_session)
    MCP::Server.new(
      name: "syrus-chat-sidecar",
      tools: [
        Mcp::Tools::SearchChatsTool,
        Mcp::Tools::ReadChatMessagesTool
      ],
      server_context: { chat_session: caller_session }
    )
  end

  def call_tool(name, arguments, caller_session = chat_session)
    raw = server(caller_session).handle_json({ jsonrpc: "2.0", id: 1, method: "tools/call", params: { name: name, arguments: arguments } }.to_json)
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

    it "excludes soft-deleted messages from search results" do
      kept = message(chat_session, text: "needle kept")
      cleared = message(chat_session, text: "needle cleared")
      [ kept, cleared ].each { |chat_message| ChatMessageSearchIndex.insert(chat_message) }
      cleared.soft_delete_by!(user)

      response = call_tool("search_chats", query: "needle")
      results = response_payload(response).fetch(:results)

      expect(results.size).to eq(1)
      expect(results.first[:created_at]).to eq(kept.created_at.iso8601)
    end

    it "excludes messages from a soft-deleted chat session, even though the messages themselves are untouched" do
      kept = message(chat_session, text: "needle kept")
      other_chat = ChatSession.create!(user: user, repository: repository, title: "Deleted chat")
      orphaned = message(other_chat, text: "needle orphaned")
      [ kept, orphaned ].each { |chat_message| ChatMessageSearchIndex.insert(chat_message) }
      other_chat.soft_delete_by!(user)

      response = call_tool("search_chats", query: "needle")
      results = response_payload(response).fetch(:results)

      expect(results.size).to eq(1)
      expect(results.first[:created_at]).to eq(kept.created_at.iso8601)
      expect(ChatMessage.active.exists?(orphaned.id)).to be(true)
    end

    it "includes soft-deleted messages for an admin caller, annotated with who deleted them" do
      kept = message(admin_chat_session, text: "needle kept")
      cleared = message(admin_chat_session, text: "needle cleared")
      [ kept, cleared ].each { |chat_message| ChatMessageSearchIndex.insert(chat_message) }
      cleared.soft_delete_by!(admin)

      response = call_tool("search_chats", { query: "needle" }, admin_chat_session)
      results = response_payload(response).fetch(:results)

      expect(results.size).to eq(2)
      deleted_result = results.find { |result| result[:snippet].include?("cleared") }
      expect(deleted_result[:deleted_at]).to eq(cleared.deleted_at.iso8601)
      expect(deleted_result[:deleted_by]).to include(id: admin.id, email: admin.email_address)
      kept_result = results.find { |result| result[:snippet].include?("kept") }
      expect(kept_result).not_to have_key(:deleted_at)
    end

    it "includes messages from a soft-deleted chat session for an admin caller, annotated with session deletion metadata" do
      kept = message(admin_chat_session, text: "needle kept")
      other_chat = ChatSession.create!(user: admin, repository: admin_repository, title: "Deleted chat")
      orphaned = message(other_chat, text: "needle orphaned")
      [ kept, orphaned ].each { |chat_message| ChatMessageSearchIndex.insert(chat_message) }
      other_chat.soft_delete_by!(admin)

      response = call_tool("search_chats", { query: "needle" }, admin_chat_session)
      results = response_payload(response).fetch(:results)

      expect(results.size).to eq(2)
      orphaned_result = results.find { |result| result[:created_at] == orphaned.created_at.iso8601 }
      expect(orphaned_result[:chat_session_deleted_at]).to eq(other_chat.deleted_at.iso8601)
      expect(orphaned_result[:chat_session_deleted_by]).to include(id: admin.id, email: admin.email_address)
    end
  end

  describe "read_chat_messages" do
    it "returns paginated messages ordered by creation time and id" do
      messages = 31.times.map { |i| message(chat_session, role: i.even? ? "user" : "assistant", text: "message #{i}") }

      response = call_tool("read_chat_messages", chat_session_id: chat_session.id, page: 2)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload[:page]).to eq(2)
      expect(payload[:has_more]).to be(false)
      expect(payload[:next_page]).to be_nil
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

    it "reports whether another page exists without counting the whole chat" do
      31.times { |i| message(chat_session, text: "message #{i}") }

      response = call_tool("read_chat_messages", chat_session_id: chat_session.id, page: 1)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload[:has_more]).to be(true)
      expect(payload[:next_page]).to eq(2)
      expect(payload[:messages].size).to eq(ChatSession::MESSAGE_PAGE_SIZE)
      expect(payload).not_to have_key(:total_pages)
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

    it "excludes soft-deleted messages" do
      kept = message(chat_session, text: "kept")
      cleared = message(chat_session, text: "cleared")
      cleared.soft_delete_by!(user)

      response = call_tool("read_chat_messages", chat_session_id: chat_session.id)
      payload = response_payload(response)

      expect(payload[:messages].map { |m| m[:id] }).to eq([ kept.id ])
    end

    it "treats a soft-deleted chat as inaccessible, even though its messages are untouched" do
      message(chat_session, text: "still here")
      chat_session.soft_delete_by!(user)

      response = call_tool("read_chat_messages", chat_session_id: chat_session.id)

      expect(response[:result][:isError]).to be(true)
      expect(response[:result][:content].first[:text]).to include("not_authorized")
    end

    it "includes soft-deleted messages for an admin caller, annotated with who deleted them" do
      kept = message(admin_chat_session, text: "kept")
      cleared = message(admin_chat_session, text: "cleared")
      cleared.soft_delete_by!(admin)

      response = call_tool("read_chat_messages", { chat_session_id: admin_chat_session.id }, admin_chat_session)
      payload = response_payload(response)

      expect(payload[:messages].map { |m| m[:id] }).to contain_exactly(kept.id, cleared.id)
      deleted_message = payload[:messages].find { |m| m[:id] == cleared.id }
      expect(deleted_message[:deleted_at]).to eq(cleared.deleted_at.iso8601)
      expect(deleted_message[:deleted_by]).to include(id: admin.id, email: admin.email_address)
      kept_message = payload[:messages].find { |m| m[:id] == kept.id }
      expect(kept_message).not_to have_key(:deleted_at)
    end

    it "lets an admin caller read a fully soft-deleted chat session, annotated with session deletion metadata" do
      still_here = message(admin_chat_session, text: "still here")
      admin_chat_session.soft_delete_by!(admin)

      response = call_tool("read_chat_messages", { chat_session_id: admin_chat_session.id }, admin_chat_session)
      payload = response_payload(response)

      expect(response[:result][:isError]).to be_falsey
      expect(payload[:messages].map { |m| m[:id] }).to eq([ still_here.id ])
      expect(payload[:chat_session_deleted_at]).to eq(admin_chat_session.deleted_at.iso8601)
      expect(payload[:chat_session_deleted_by]).to include(id: admin.id, email: admin.email_address)
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
