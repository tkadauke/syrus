require "rails_helper"

RSpec.describe BackfillChatSearchIndexJob do
  let(:repo) { Factories.repository }
  let(:session) { ChatSession.create!(repository: repo, user: repo.user) }

  before do
    allow(AppEvents).to receive(:broadcast)
    prepare_search_tables
    stub_const("#{described_class}::BATCH_SIZE", 2)
  end

  it "processes messages in batches and records progress" do
    first = ChatMessage.create!(chat_session: session, role: "user", content: { "text" => "first searchable" })
    second = ChatMessage.create!(chat_session: session, role: "assistant", content: { "text" => "second searchable" })
    tool = ChatMessage.create!(chat_session: session, role: "tool_use", content: { "name" => "inspect_repo" })
    third = ChatMessage.create!(chat_session: session, role: "user", content: { "text" => "third searchable" })

    described_class.perform_now

    expect(indexed_message_ids).to eq([ first.id, second.id, third.id ])
    expect(metadata_value("last_backfilled_id")).to eq(third.id.to_s)
    expect(metadata_value("indexed_chat_message:#{tool.id}")).to be_nil
  end

  it "resumes from the last backfilled id and skips messages already indexed" do
    already_indexed = ChatMessage.create!(chat_session: session, role: "user", content: { "text" => "already indexed" })
    pending = ChatMessage.create!(chat_session: session, role: "assistant", content: { "text" => "pending index" })
    ChatMessageSearchIndex.insert(already_indexed)
    write_metadata("last_backfilled_id", "0")

    expect(indexed_message_ids.count(already_indexed.id)).to eq(1)

    expect {
      described_class.perform_now
    }.to change { indexed_message_ids.count(pending.id) }.from(0).to(1)

    expect(indexed_message_ids.count(already_indexed.id)).to eq(1)

    expect(metadata_value("last_backfilled_id")).to eq(pending.id.to_s)
  end

  it "is idempotent on re-run" do
    message = ChatMessage.create!(chat_session: session, role: "user", content: { "text" => "once only" })

    described_class.perform_now

    expect {
      described_class.perform_now
    }.not_to change { indexed_message_ids.count(message.id) }
  end

  def indexed_message_ids
    SearchRecord.connection.select_values("SELECT chat_message_id FROM chat_message_fts ORDER BY chat_message_id").map(&:to_i)
  end

  def metadata_value(key)
    SearchRecord.connection.select_value(
      "SELECT value FROM chat_search_metadata WHERE key = ?",
      "BackfillChatSearchIndexJobSpec Metadata",
      [ bind(key) ]
    )
  end

  def write_metadata(key, value)
    SearchRecord.connection.exec_insert(
      "INSERT OR REPLACE INTO chat_search_metadata (key, value) VALUES (?, ?)",
      "BackfillChatSearchIndexJobSpec Write Metadata",
      [ bind(key), bind(value) ]
    )
  end

  def bind(value)
    ActiveRecord::Relation::QueryAttribute.new(nil, value, ActiveRecord::Type::Value.new)
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
