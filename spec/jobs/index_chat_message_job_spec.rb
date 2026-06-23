require "rails_helper"

RSpec.describe IndexChatMessageJob do
  let(:repo) { Factories.repository }
  let(:session) { ChatSession.create!(repository: repo, user: repo.user) }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  it "inserts a valid user message into the search index" do
    message = ChatMessage.create!(chat_session: session, role: "user", content: { "text" => "Find this later." })

    expect {
      described_class.perform_now(message.id)
    }.to change { indexed_message_ids }.from([]).to([ message.id ])
  end

  it "skips blank message content" do
    message = ChatMessage.create!(chat_session: session, role: "user", content: {})

    expect {
      described_class.perform_now(message.id)
    }.not_to change { indexed_message_ids }
  end

  it "skips tool-only messages" do
    message = ChatMessage.create!(chat_session: session, role: "tool_use", content: { "name" => "read_live_state" })

    expect {
      described_class.perform_now(message.id)
    }.not_to change { indexed_message_ids }
  end

  def indexed_message_ids
    SearchRecord.connection.select_values("SELECT chat_message_id FROM chat_message_fts ORDER BY chat_message_id").map(&:to_i)
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
