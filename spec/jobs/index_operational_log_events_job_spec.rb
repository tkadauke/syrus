require "rails_helper"

RSpec.describe IndexOperationalLogEventsJob do
  before do
    Feature.where(slug: "operational_log_indexing").delete_all
    Feature.create!(slug: "operational_log_indexing", category: "Operations", name: "Operational log indexing", enabled: true)
    Feature.clear_enabled_cache!("operational_log_indexing")
    Factories.repository(user: Factories.user, owner: "tkadauke", name: "syrus")
    Current.reset
  end

  after { Current.reset }

  it "indexes existing events without deleting rows that are present in the batch" do
    prepare_search_tables
    event = OperationalLogEvent.create!(
      occurred_at: Time.current,
      level: "info",
      role: "web",
      hostname: "host-a",
      source: "spec",
      message: "batched index me",
      context: {}
    )

    delete_sql = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      delete_sql << payload[:sql] if payload[:name] == "OperationalLogIndex Delete Many"
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.perform_now([ event.id ])
      described_class.perform_now([ event.id ])
    end

    expect(OperationalLogIndex.search(query: "batched", since: 1.hour.ago).map { |row| row[:operational_log_event_id] }).to eq([ event.id ])
    expect(delete_sql).to be_empty
  end

  it "indexes multiple existing events with one batched insert" do
    prepare_search_tables
    event_one = OperationalLogEvent.create!(
      occurred_at: Time.current,
      level: "info",
      role: "web",
      hostname: "host-a",
      source: "spec",
      message: "first batched event",
      context: {}
    )
    event_two = OperationalLogEvent.create!(
      occurred_at: Time.current,
      level: "info",
      role: "web",
      hostname: "host-a",
      source: "spec",
      message: "second batched event",
      context: {}
    )

    insert_sql = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      insert_sql << payload[:sql] if payload[:name] == "OperationalLogIndex Upsert Many"
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.perform_now([ event_one.id, event_two.id ])
    end

    expect(insert_sql.size).to eq(1)
    expect(insert_sql.first).to match(/VALUES \(.+\), \(/)
    expect(OperationalLogIndex.search(query: "batched", since: 1.hour.ago).map { |row| row[:operational_log_event_id] }).to contain_exactly(event_one.id, event_two.id)
  end

  it "does not delete stale index rows for missing events in the hot indexing path" do
    prepare_search_tables
    event = OperationalLogEvent.create!(
      occurred_at: Time.current,
      level: "info",
      role: "web",
      hostname: "host-a",
      source: "spec",
      message: "stale event in batch",
      context: {}
    )
    OperationalLogIndex.upsert(event)
    event.destroy!

    described_class.perform_now([ event.id ])

    expect(OperationalLogIndex.search(query: "stale", since: 1.hour.ago).map { |row| row[:operational_log_event_id] }).to eq([ event.id ])
  end

  it "indexes the whole batch inside a single outer transaction, rolling back all events if insertion fails" do
    prepare_search_tables
    event_one = OperationalLogEvent.create!(
      occurred_at: Time.current,
      level: "info",
      role: "web",
      hostname: "host-a",
      source: "spec",
      message: "first event in batch",
      context: {}
    )
    event_two = OperationalLogEvent.create!(
      occurred_at: Time.current,
      level: "info",
      role: "web",
      hostname: "host-a",
      source: "spec",
      message: "second event in batch",
      context: {}
    )

    allow(OperationalLogIndex.connection).to receive(:exec_insert).and_wrap_original do |original, *args|
      raise ActiveRecord::StatementInvalid, "boom" if args.second == "OperationalLogIndex Upsert Many"

      original.call(*args)
    end

    expect {
      described_class.perform_now([ event_one.id, event_two.id ])
    }.to raise_error(ActiveRecord::StatementInvalid)

    expect(
      OperationalLogIndex.search(query: "first", since: 1.hour.ago).map { |row| row[:operational_log_event_id] }
    ).not_to include(event_one.id)
  end

  def prepare_search_tables
    SearchRecord.connection.execute("DROP TABLE IF EXISTS operational_log_fts")
    SearchRecord.connection.execute(<<~SQL)
      CREATE VIRTUAL TABLE operational_log_fts
      USING fts5(
        message,
        context_text,
        context_json UNINDEXED,
        operational_log_event_id UNINDEXED,
        occurred_at UNINDEXED,
        level UNINDEXED,
        role UNINDEXED,
        hostname UNINDEXED,
        app_revision UNINDEXED,
        pid UNINDEXED,
        source UNINDEXED,
        job_id UNINDEXED,
        workflow_id UNINDEXED,
        run_id UNINDEXED,
        request_id UNINDEXED,
        tokenize = 'porter unicode61'
      )
    SQL
  end
end
