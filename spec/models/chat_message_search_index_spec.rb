require "rails_helper"

RSpec.describe ChatMessageSearchIndex do
  let(:user) { Factories.user }
  let(:other_user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }
  let(:other_repo) { Factories.repository(user: other_user) }
  let(:session) { ChatSession.create!(repository: repo, user: user) }
  let(:other_session) { ChatSession.create!(repository: other_repo, user: other_user) }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
  end

  it "inserts a chat message and finds it by FTS query" do
    message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "Remember the deploy checklist for search." }
    )

    described_class.insert(message)

    results = described_class.search("deploy", user_id: user.id)

    expect(results.length).to eq(1)
    expect(results.first).to include(
      chat_message_id: message.id,
      chat_session_id: session.id,
      user_id: user.id,
      role: "user"
    )
    expect(results.first[:snippet]).to include("<mark>deploy</mark>")
  end

  it "scopes results to the requested user" do
    own_message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "wal search scope" }
    )
    other_message = ChatMessage.create!(
      chat_session: other_session,
      role: "user",
      content: { "text" => "wal search scope" }
    )
    described_class.insert(own_message)
    described_class.insert(other_message)

    results = described_class.search("scope", user_id: user.id)

    expect(results.map { |row| row[:chat_message_id] }).to eq([ own_message.id ])
  end

  it "treats hyphenated queries as FTS literals" do
    message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "Review JOB-1 search behavior" }
    )
    described_class.insert(message)

    results = described_class.search("JOB-1", user_id: user.id)

    expect(results.map { |row| row[:chat_message_id] }).to eq([ message.id ])
  end

  it "orders more relevant matches first using BM25 rank" do
    weaker = ChatMessage.create!(
      chat_session: session,
      role: "assistant",
      content: { "text" => "needle deployment" }
    )
    stronger = ChatMessage.create!(
      chat_session: session,
      role: "assistant",
      content: { "text" => "needle needle needle deployment" }
    )
    described_class.insert(weaker)
    described_class.insert(stronger)

    results = described_class.search("needle", user_id: user.id)

    expect(results.map { |row| row[:chat_message_id] }).to start_with(stronger.id, weaker.id)
    expect(results.first[:rank]).to be < results.second[:rank]
  end

  it "sets WAL mode and normal synchronous mode on the search connection" do
    connection = SearchRecord.connection

    expect(connection.select_value("PRAGMA journal_mode")).to eq("wal")
    expect(connection.select_value("PRAGMA synchronous")).to eq(1)
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
