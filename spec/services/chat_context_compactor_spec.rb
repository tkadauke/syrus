require "rails_helper"

RSpec.describe ChatContextCompactor do
  let(:user) { Factories.user(admin: true) }

  before do
    allow(AppEvents).to receive(:broadcast)
    allow(IndexChatMessageJob).to receive(:perform_later)
    Feature.clear_enabled_cache!
    Observability::EventSink.clear!
    Current.reset
  end

  after do
    Feature.clear_enabled_cache!
    Observability::EventSink.clear!
    Current.reset
  end

  def enable_operational_log_indexing!
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
  end

  def enable_compaction!
    Feature.create!(
      slug: "chat_context_compaction",
      category: "Operations",
      name: "Chat context compaction",
      enabled: true
    )
    Feature.clear_enabled_cache!
  end

  def chat(supervisor: true)
    ChatSession.create!(
      user: user,
      title: supervisor ? "Supervisor" : "Planning",
      system_kind: supervisor ? "supervisor" : nil,
      chat_provider: "codex"
    )
  end

  def add_messages(chat_session, count)
    count.times do |i|
      role = i.even? ? "assistant" : "tool_result"
      content = if role == "assistant"
        [ { "type" => "text", "text" => "assistant event #{i}" } ]
      else
        {
          "type" => "tool_result",
          "tool_use_id" => "tool-#{i}",
          "content" => "large operational result #{i} " + ("x" * 1_000),
          "is_error" => false
        }
      end
      chat_session.messages.create!(role: role, content: content, tool_name: role == "tool_result" ? "admin.tool" : nil, tool_use_id: role == "tool_result" ? "tool-#{i}" : nil)
    end
  end

  it "does nothing while the feature is disabled" do
    session = chat
    add_messages(session, 130)

    expect {
      described_class.maybe_compact!(session)
    }.not_to change { ChatContextCheckpoint.count }
  end

  it "does not compact ordinary chats when the feature is enabled" do
    enable_compaction!
    session = chat(supervisor: false)
    add_messages(session, 130)

    expect {
      described_class.maybe_compact!(session)
    }.not_to change { ChatContextCheckpoint.count }
  end

  it "stores a checkpoint for old Supervisor messages and preserves all durable messages" do
    enable_compaction!
    session = chat
    add_messages(session, 130)

    expect {
      described_class.maybe_compact!(session)
    }.to change { session.context_checkpoints.count }.by(1)

    checkpoint = session.context_checkpoints.latest_first.first
    expect(checkpoint.source_message_count).to eq(90)
    expect(checkpoint.summary).to include("Compacted 90 older messages")
    expect(session.messages.count).to eq(130)
  end

  it "returns a synthetic summary plus recent raw messages for provider replay" do
    enable_compaction!
    session = chat
    add_messages(session, 130)
    described_class.maybe_compact!(session)

    messages = described_class.context_messages_for(session)

    expect(messages.size).to eq(41)
    expect(messages.first.role).to eq("assistant")
    expect(messages.first.content.first["text"]).to include("Prior durable chat context summary")
    expect(messages.drop(1).map(&:id)).to eq(session.messages.order(:id).last(40).map(&:id))
  end

  it "compacts only messages after the previous checkpoint" do
    enable_compaction!
    session = chat
    add_messages(session, 130)
    first = described_class.maybe_compact!(session)

    add_messages(session, 10)
    second = described_class.maybe_compact!(session)

    expect(second.compacted_through_message_id).to be > first.compacted_through_message_id
    expect(second.source_message_count).to eq(100)
    expect(second.summary).to include("Compacted 10 older messages")
    expect(second.summary).to include("Previous checkpoint: through ChatMessage ##{first.compacted_through_message_id}")
  end

  it "records an operational log event with compaction metrics for each compaction run" do
    Factories.repository(user: user, owner: "tkadauke", name: "syrus")
    enable_compaction!
    enable_operational_log_indexing!
    session = chat
    add_messages(session, 130)

    checkpoint = nil
    expect {
      checkpoint = described_class.maybe_compact!(session)
      Observability::EventSink.flush!(kinds: [ :operational ])
    }.to change(OperationalLogEvent, :count).by(1)

    event = OperationalLogEvent.last
    expect(event.level).to eq("info")
    expect(event.source).to eq("chat_context_compactor")
    expect(event.message).to eq("Compacted 90 messages for chat #{session.id} (kept 40 raw)")
    expect(event.context).to include(
      "chat_session_id" => session.id.to_s,
      "checkpoint_id" => checkpoint.id.to_s,
      "checkpoint_number" => "1",
      "messages_compacted_this_run" => "90",
      "messages_kept_raw" => "40",
      "cumulative_messages_compacted" => "90"
    )
    expect(event.context["estimated_compacted_context_bytes"].to_i).to be > 0
    expect(event.context["estimated_kept_context_bytes"].to_i).to be > 0
    expect(event.context["session_age_seconds"].to_i).to be >= 0
  end

  it "does not record an operational log event when no compaction happens" do
    Factories.repository(user: user, owner: "tkadauke", name: "syrus")
    enable_compaction!
    enable_operational_log_indexing!
    session = chat
    add_messages(session, 10)

    expect {
      described_class.maybe_compact!(session)
      Observability::EventSink.flush!(kinds: [ :operational ])
    }.not_to change(OperationalLogEvent, :count)
  end

  it "still logs the compaction event when operational log indexing is disabled" do
    enable_compaction!
    session = chat
    add_messages(session, 130)

    events = []
    subscription = ActiveSupport::Notifications.subscribe("chat_context_compactor.compacted") { |*args| events << ActiveSupport::Notifications::Event.new(*args) }

    expect {
      described_class.maybe_compact!(session)
    }.not_to change(OperationalLogEvent, :count)

    expect(events.size).to eq(1)
    expect(events.first.payload).to include(messages_compacted_this_run: 90)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription) if subscription
  end

  it "still returns the checkpoint and does not raise when recording compaction metrics fails" do
    enable_compaction!
    session = chat
    add_messages(session, 130)

    allow(OperationalLogging).to receive(:ingest).and_raise("boom")
    allow(Rails.logger).to receive(:warn)

    checkpoint = nil
    expect {
      checkpoint = described_class.maybe_compact!(session)
    }.not_to raise_error

    expect(checkpoint).to be_a(ChatContextCheckpoint)
    expect(checkpoint).to be_persisted
    expect(Rails.logger).to have_received(:warn).with(/failed to record compaction metrics/)
  end

  it "excludes the current unanswered user message from the kept-raw metrics" do
    Factories.repository(user: user, owner: "tkadauke", name: "syrus")
    enable_compaction!
    enable_operational_log_indexing!
    session = chat
    add_messages(session, 130)
    session.messages.create!(role: "user", content: [ { "type" => "text", "text" => "still typing" } ])

    described_class.maybe_compact!(session)
    Observability::EventSink.flush!(kinds: [ :operational ])

    event = OperationalLogEvent.last
    expect(event.context["messages_kept_raw"]).to eq("39")
  end

  it "finds the compaction cutoff without counting the whole transcript" do
    enable_compaction!
    session = chat
    add_messages(session, 130)

    queries = capture_sql { described_class.maybe_compact!(session) }

    expect(queries.grep(/COUNT\\(\\*\\).*chat_messages/i)).to be_empty
    expect(session.context_checkpoints.latest_first.first.source_message_count).to eq(90)
  end

  it "forces the chat message cursor index on MySQL" do
    session = chat
    compactor = described_class.new(session)

    allow(ActiveRecord::Base.connection).to receive(:adapter_name).and_return("Mysql2")

    expect(compactor.send(:messages_scope).to_sql).to include(
      "FORCE INDEX (index_chat_messages_on_session_id_and_id)"
    )
  end

  def capture_sql
    queries = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _started, _finished, _id, payload|
      sql = payload[:sql].to_s
      queries << sql unless payload[:name] == "SCHEMA" || sql.include?("sqlite_master")
    end
    yield
    queries
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
