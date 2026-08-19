require "rails_helper"

RSpec.describe OperationalLogIndex do
  before do
    prepare_search_tables
  end

  it "indexes and searches operational log events with filters" do
    matching = event(message: "grader failed with missing migration", level: "error", role: "worker", hostname: "host-a")
    event(message: "request finished", level: "info", role: "web", hostname: "host-b")

    described_class.upsert(matching)
    described_class.upsert(OperationalLogEvent.last)

    results = described_class.search(query: "migration", level: "error", role: "worker", hostname: "host-a")

    expect(results.map { |row| row[:operational_log_event_id] }).to eq([ matching.id ])
    expect(results.first).to include(
      level: "error",
      role: "worker",
      hostname: "host-a",
      message: "grader failed with missing migration"
    )
  end

  it "returns recent rows without an FTS query" do
    older = event(message: "older event", occurred_at: 2.hours.ago)
    newer = event(message: "newer event", occurred_at: 5.minutes.ago)
    described_class.upsert(older)
    described_class.upsert(newer)

    expect(described_class.search(since: 3.hours.ago).map { |row| row[:operational_log_event_id] }).to eq([ newer.id, older.id ])
  end

  it "memoizes table availability instead of re-querying sqlite_master on every call" do
    described_class.reset_availability_cache!
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      queries << payload[:sql].to_s if payload[:sql].to_s.include?("sqlite_master")
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      3.times { described_class.available? }
    end

    expect(queries.size).to eq(1)
  end

  it "recomputes availability after an explicit cache reset" do
    expect(described_class.available?).to be(true)

    SearchRecord.connection.execute("DROP TABLE IF EXISTS operational_log_fts")
    described_class.reset_availability_cache!

    expect(described_class.available?).to be(false)
  end

  it "filters by upper time bound, app revision, limit, and offset" do
    old_revision = event(message: "old revision", occurred_at: 40.minutes.ago, app_revision: "old-sha")
    older = event(message: "older current", occurred_at: 30.minutes.ago, app_revision: "current-sha")
    newer = event(message: "newer current", occurred_at: 10.minutes.ago, app_revision: "current-sha")
    [ old_revision, older, newer ].each { |record| described_class.upsert(record) }

    results = described_class.search(
      since: 1.hour.ago,
      until_time: 5.minutes.ago,
      app_revision: "current-sha",
      limit: 1,
      offset: 1
    )

    expect(results.map { |row| row[:operational_log_event_id] }).to eq([ older.id ])
  end

  def event(**attrs)
    OperationalLogEvent.create!({
      occurred_at: Time.current,
      level: "info",
      role: "worker",
      hostname: "host-a",
      source: "spec",
      message: "message",
      context: { "token" => "token=[REDACTED]" }
    }.merge(attrs))
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
