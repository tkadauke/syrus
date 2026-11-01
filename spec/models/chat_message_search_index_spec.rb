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

    results = described_class.search("deploy", chat_session_ids: [ session.id ])

    expect(results.length).to eq(1)
    expect(results.first).to include(
      chat_message_id: message.id,
      chat_session_id: session.id,
      user_id: user.id,
      role: "user"
    )
    expect(results.first[:snippet]).to include("<mark>deploy</mark>")
  end

  it "indexes only readable text from canonical assistant content" do
    message = ChatMessage.create!(
      chat_session: session,
      role: "assistant",
      content: [
        { "type" => "thinking", "thinking" => "secret deployment reasoning" },
        { "type" => "text", "text" => "First deployment line.\n" },
        { "type" => "tool_use", "name" => "inspect_repo", "input" => {} },
        { "type" => "text", "text" => "Second readable line." }
      ]
    )

    described_class.insert(message)

    snippet = described_class.search("deployment", chat_session_ids: [ session.id ]).sole.fetch(:snippet)
    expect(snippet).to include("First <mark>deployment</mark> line.\nSecond readable line.")
    expect(snippet).not_to include("[{", '"type"', "thinking", "secret", "\\n")
  end

  it "skips inserting when the message's chat session no longer exists" do
    message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "Indexed after the chat was deleted." }
    )
    # Simulate the deletion race: an IndexChatMessageJob loaded the
    # message just before the chat (and its rows) were hard-deleted and
    # ChatSessionCleanupJob purged the index. Re-inserting now would
    # orphan an FTS row forever.
    session.destroy!

    expect { described_class.insert(message) }.not_to raise_error

    expect(described_class.search("deleted", chat_session_ids: [ session.id ])).to be_empty
  end

  it "skips inserting when the message's chat session is soft-deleted" do
    message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "Indexed after the chat was soft-deleted." }
    )
    session.soft_delete_by!(user)

    expect { described_class.insert(message) }.not_to raise_error

    expect(described_class.search("deleted", chat_session_ids: [ session.id ])).to be_empty
  end

  it "uses active messages in active chat sessions as the canonical rebuild eligibility scope" do
    active_message = ChatMessage.create!(chat_session: session, role: "user", content: { "text" => "active search message" })
    deleted_message = ChatMessage.create!(chat_session: session, role: "user", content: { "text" => "deleted search message" })
    deleted_message.soft_delete_by!(user)

    deleted_session = ChatSession.create!(repository: repo, user: user)
    deleted_session_message = ChatMessage.create!(chat_session: deleted_session, role: "assistant", content: { "text" => "deleted chat message" })
    deleted_session.soft_delete_by!(user)

    orphaned_session = ChatSession.create!(repository: repo, user: user)
    orphaned_message = ChatMessage.create!(chat_session: orphaned_session, role: "user", content: { "text" => "orphaned search message" })
    ChatSession.where(id: orphaned_session.id).delete_all

    expect(described_class.search_eligible_scope).to contain_exactly(active_message)
    expect(described_class.search_database_rebuild_units).to eq(1)
    expect(described_class.search_database_integrity_repair_needed?).to be(true)

    described_class.insert(active_message)

    expect(described_class.search_database_integrity_repair_needed?).to be(false)
    expect(described_class.indexed?(active_message.id)).to be(true)
    expect(described_class.indexed?(deleted_message.id)).to be(false)
    expect(described_class.indexed?(deleted_session_message.id)).to be(false)
    expect(described_class.indexed?(orphaned_message.id)).to be(false)
  end

  it "rechecks the active chat session when a rebuild message is deleted mid-batch" do
    message = ChatMessage.create!(chat_session: session, role: "user", content: { "text" => "delete during rebuild" })
    task = MaintenanceTask.new(batch_size: 10, checkpoint: {})
    chat_session = session
    actor = user
    deleted = false
    task.define_singleton_method(:checkpoint_will_change!) do
      next if deleted

      chat_session.soft_delete_by!(actor)
      deleted = true
    end

    described_class.search_database_rebuild_batch(task: task, reason: "integrity_repair")

    expect(described_class.indexed?(message.id)).to be(false)
    expect(described_class.search("rebuild", chat_session_ids: [ session.id ])).to be_empty
    expect(task.checkpoint["chats_done"]).to be(true)
    expect(described_class.search_database_integrity_repair_needed?).to be(false)
  end

  it "scopes results to the requested chat sessions" do
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

    results = described_class.search("scope", chat_session_ids: [ session.id ])

    expect(results.map { |row| row[:chat_message_id] }).to eq([ own_message.id ])
  end

  it "can scope results to accessible chat session ids instead of owner user id" do
    own_message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "participant scoped search" }
    )
    other_message = ChatMessage.create!(
      chat_session: other_session,
      role: "user",
      content: { "text" => "participant scoped search" }
    )
    described_class.insert(own_message)
    described_class.insert(other_message)

    results = described_class.search("participant", chat_session_ids: [ other_session.id ])

    expect(results.map { |row| row[:chat_message_id] }).to eq([ other_message.id ])
  end

  it "returns no results without an explicit chat-session scope" do
    message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "unscoped private search" }
    )
    described_class.insert(message)

    expect(described_class.search("unscoped")).to be_empty
  end

  it "matches unquoted words as independent AND terms" do
    matching_message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "bar release foo" }
    )
    partial_message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "foo only" }
    )
    described_class.insert(matching_message)
    described_class.insert(partial_message)

    results = described_class.search("foo bar", chat_session_ids: [ session.id ])

    expect(results.map { |row| row[:chat_message_id] }).to eq([ matching_message.id ])
  end

  it "preserves quoted phrases" do
    phrase_message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "foo bar release" }
    )
    reordered_message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "bar foo release" }
    )
    described_class.insert(phrase_message)
    described_class.insert(reordered_message)

    results = described_class.search('"foo bar"', chat_session_ids: [ session.id ])

    expect(results.map { |row| row[:chat_message_id] }).to eq([ phrase_message.id ])
  end

  it "mixes independent terms with quoted phrases" do
    matching_message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "foo release bar baz" }
    )
    scattered_message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "foo bar release baz" }
    )
    described_class.insert(matching_message)
    described_class.insert(scattered_message)

    results = described_class.search('foo "bar baz"', chat_session_ids: [ session.id ])

    expect(results.map { |row| row[:chat_message_id] }).to eq([ matching_message.id ])
  end

  it "treats hyphenated queries as FTS literals" do
    message = ChatMessage.create!(
      chat_session: session,
      role: "user",
      content: { "text" => "Review JOB-1 search behavior" }
    )
    described_class.insert(message)

    results = described_class.search("JOB-1", chat_session_ids: [ session.id ])

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

    results = described_class.search("needle", chat_session_ids: [ session.id ])

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
