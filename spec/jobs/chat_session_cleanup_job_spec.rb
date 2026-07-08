require "rails_helper"
require "tmpdir"

RSpec.describe ChatSessionCleanupJob do
  let(:user) { Factories.user }

  before do
    @data_root = Dir.mktmpdir("syrus-chat-cleanup")
    ENV["SYRUS_DATA_ROOT"] = @data_root
  end

  after do
    ENV.delete("SYRUS_DATA_ROOT")
    FileUtils.rm_rf(@data_root) if @data_root
  end

  def data_root
    Pathname.new(@data_root)
  end

  it "runs on the chat queue so it executes on the worker pod" do
    expect(described_class.new.queue_name).to eq("chat")
  end

  it "removes the workspace, the per-chat agent homes, and the FTS rows once the chat row is gone" do
    prepare_search_tables
    chat = ChatSession.create!(user: user)
    message = chat.messages.create!(role: "user", content: { "text" => "Aqueduct feasibility" })
    ChatMessageSearchIndex.insert(message)
    expect(ChatMessageSearchIndex.search("aqueduct", user_id: user.id)).not_to be_empty

    workspace = ChatWorkspace.ensure_root!(chat)
    agent_home = ChatWorkspace.agent_home_for(chat, "codex")
    FileUtils.mkdir_p(agent_home.to_s)
    FileUtils.touch(agent_home.join("auth.json").to_s)

    id = chat.id
    recorded_path = chat.reload.workspace_path
    chat.destroy!

    described_class.perform_now(id, recorded_path)

    expect(workspace).not_to exist
    expect(data_root.join("agent_homes", "chats", id.to_s)).not_to exist
    expect(ChatMessageSearchIndex.search("aqueduct", user_id: user.id)).to be_empty
  end

  it "no-ops when the ChatSession still exists — a live chat's workspace is never deleted" do
    prepare_search_tables
    chat = ChatSession.create!(user: user)
    message = chat.messages.create!(role: "user", content: { "text" => "Aqueduct feasibility" })
    ChatMessageSearchIndex.insert(message)
    workspace = ChatWorkspace.ensure_root!(chat)
    agent_home = ChatWorkspace.agent_home_for(chat, "codex")
    FileUtils.mkdir_p(agent_home.to_s)

    described_class.perform_now(chat.id, chat.reload.workspace_path)

    expect(workspace).to exist
    expect(agent_home).to exist
    expect(ChatMessageSearchIndex.search("aqueduct", user_id: user.id)).not_to be_empty
  end

  it "ignores a recorded workspace path outside SYRUS_DATA_ROOT instead of rm_rf'ing it" do
    outside = Pathname.new(Dir.mktmpdir("syrus-outside-data-root"))
    FileUtils.touch(outside.join("keep.txt").to_s)
    chat = ChatSession.create!(user: user)
    id = chat.id
    chat.destroy!

    described_class.perform_now(id, outside.to_s)

    expect(outside.join("keep.txt")).to exist
  ensure
    FileUtils.rm_rf(outside.to_s) if outside
  end

  it "no-ops on garbage ids rather than deriving paths from them" do
    expect { described_class.perform_now("not-a-number", nil) }.not_to raise_error
    expect { described_class.perform_now(-4, nil) }.not_to raise_error
    expect { described_class.perform_now(0, nil) }.not_to raise_error
  end

  it "survives a missing search schema" do
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_search_metadata")
    chat = ChatSession.create!(user: user)
    id = chat.id
    chat.destroy!

    expect { described_class.perform_now(id, nil) }.not_to raise_error
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
