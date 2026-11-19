require "rails_helper"

RSpec.describe Coworkers::ConversationIndex do
  let(:owner) { Factories.user }
  let(:coworker) do
    Coworkers::Coworker.create!(owner_user: owner, name: "Maya", handle: "maya-conversations",
      workspace_repo: "https://github.com/acme/workspace.git")
  end

  before do
    PluginRecord.find_by!(name: "coworkers").update!(enabled: true)
    SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE chat_message_fts
      USING fts5(content, user_id UNINDEXED, chat_session_id UNINDEXED, chat_message_id UNINDEXED, role UNINDEXED, created_at UNINDEXED, tokenize = 'porter unicode61')
    SQL
    SearchRecord.connection.execute("CREATE TABLE IF NOT EXISTS chat_search_metadata (key TEXT PRIMARY KEY, value TEXT)")
  end

  after { SearchRecord.connection.execute("DROP TABLE IF EXISTS chat_message_fts") }

  it "pins the main chat and excludes mention sessions from side-chat results" do
    main = linked_chat("Main", role: "main")
    side = linked_chat("Side", role: "side")
    source = ChatSession.create!(user: owner, title: "Source")
    mention = ChatSession.create!(user: owner, title: "Hidden mention")
    Coworkers::Chat.create!(coworker: coworker, chat_session: mention, source_chat_session: source, role: "mention")

    payload = described_class.new(coworker: coworker, user: owner).call

    expect(payload.dig(:main_chat, :id)).to eq(main.id)
    expect(payload.fetch(:side_chats).pluck(:id)).to eq([ side.id ])
  end

  it "searches titles and indexed message content without leaking another coworker or owner" do
    title_match = linked_chat("Needle planning", role: "side")
    body_match = linked_chat("Research", role: "side")
    message = body_match.messages.create!(role: "user", content: { "text" => "A substantive needle in the message" })
    ChatMessageSearchIndex.insert(message)
    other_coworker = Coworkers::Coworker.create!(owner_user: owner, name: "Ada", handle: "ada-conversations",
      workspace_repo: "https://github.com/acme/workspace.git")
    other_chat = ChatSession.create!(user: owner, title: "Needle elsewhere")
    Coworkers::Chat.create!(coworker: other_coworker, chat_session: other_chat, role: "side")
    foreign_owner = Factories.user(email_address: "conversation-owner@example.com")
    foreign = ChatSession.create!(user: foreign_owner, title: "Needle private")

    payload = described_class.new(coworker: coworker, user: owner, filter: encoded_filter("search", "contains", "needle")).call

    expect(payload.fetch(:side_chats).pluck(:id)).to contain_exactly(title_match.id, body_match.id)
    expect(payload.fetch(:side_chats).find { |chat| chat[:id] == body_match.id }).to include(
      match_count: 1, match: include(message_id: message.id, snippet: include("<mark>needle</mark>"))
    )
    expect(payload.fetch(:side_chats).pluck(:id)).not_to include(other_chat.id, foreign.id)
  end

  it "combines archived, unread, created, and active-work predicates" do
    travel_to Time.zone.parse("2026-11-18 12:00:00 UTC") do
      matching = linked_chat("Matching", role: "side", created_at: 2.days.ago, last_message_at: 1.hour.ago, turn_in_flight: true)
      matching.chat_participants.find_by!(user: owner).update!(hidden_at: 30.minutes.ago, last_read_at: 2.hours.ago)
      linked_chat("Too old", role: "side", created_at: 20.days.ago, last_message_at: 1.hour.ago, turn_in_flight: true)
      filters = Filters::QueryParam.encode("and" => [
        { "field" => "status", "op" => "is", "value" => "archived" },
        { "field" => "unread", "op" => "is_true" },
        { "field" => "active_work", "op" => "is_true" },
        { "field" => "created_at", "op" => "after", "value" => 1.week.ago.iso8601 }
      ])

      payload = described_class.new(coworker: coworker, user: owner, filter: filters).call

      expect(payload.fetch(:side_chats).pluck(:id)).to eq([ matching.id ])
      expect(payload.fetch(:side_chats).first).to include(archived: true, unread: true, active_work: true)
    end
  end

  it "uses stable cursor pagination for default and alternate sorts" do
    stub_const("Coworkers::ConversationIndex::PAGE_SIZE", 2)
    chats = [
      linked_chat("Charlie", role: "side", last_message_at: 3.hours.ago),
      linked_chat("Alpha", role: "side", last_message_at: 1.hour.ago),
      linked_chat("Bravo", role: "side", last_message_at: 2.hours.ago)
    ]

    first = described_class.new(coworker: coworker, user: owner).call
    second = described_class.new(coworker: coworker, user: owner, cursor: first.fetch(:next_cursor)).call
    titled = described_class.new(coworker: coworker, user: owner, sort: "title").call

    expect(first.fetch(:side_chats).pluck(:id) + second.fetch(:side_chats).pluck(:id)).to eq([ chats[1].id, chats[2].id, chats[0].id ])
    expect(titled.fetch(:side_chats).pluck(:title)).to eq(%w[Alpha Bravo])
  end

  it "rejects a cursor whose value is invalid for the selected sort" do
    cursor = Base64.urlsafe_encode64(JSON.generate([ "not-a-date", 42 ]), padding: false)

    expect {
      described_class.new(coworker: coworker, user: owner, cursor: cursor).call
    }.to raise_error(described_class::InvalidCursor, "invalid conversation cursor")
  end

  it "loads previews and indicators without per-chat queries" do
    5.times do |index|
      chat = linked_chat("Chat #{index}", role: "side", last_message_at: index.minutes.ago)
      chat.messages.create!(role: "user", content: { "text" => "Preview #{index}" })
    end
    small = sql_queries { described_class.new(coworker: coworker, user: owner).call }.size
    10.times do |index|
      chat = linked_chat("More #{index}", role: "side", last_message_at: index.minutes.ago)
      chat.messages.create!(role: "user", content: { "text" => "More preview #{index}" })
    end

    large = sql_queries { described_class.new(coworker: coworker, user: owner).call }.size

    expect(large).to be <= small + 1
  end

  private

  def sql_queries
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql] unless payload[:cached] || payload[:name] == "SCHEMA"
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def linked_chat(title, role:, **attributes)
    ChatSession.create!(user: owner, title: title, **attributes).tap do |chat|
      Coworkers::Chat.create!(coworker: coworker, chat_session: chat, role: role)
    end
  end

  def encoded_filter(field, op, value)
    Filters::QueryParam.encode("and" => [ { "field" => field, "op" => op, "value" => value } ])
  end
end
