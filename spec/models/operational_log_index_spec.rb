require "rails_helper"

RSpec.describe OperationalLogIndex do
  before do
    prepare_search_tables
  end

  after do
    described_class.reset_freshness_check!
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

  it "searches messages containing FTS5-significant punctuation without raising" do
    namespaced = event(message: "SolidCable::TrimJob 0.7ms executions=1 queue_name=default")
    key_value = event(message: "job_id=42 workflow_id=7 run_id=3")
    path = event(message: "POST /api/v1/app/performance_events 202 7.7ms")
    [ namespaced, key_value, path ].each { |record| described_class.upsert(record) }

    expect(described_class.search(query: "SolidCable::TrimJob").map { |row| row[:operational_log_event_id] }).to eq([ namespaced.id ])
    expect(described_class.search(query: "job_id=42").map { |row| row[:operational_log_event_id] }).to eq([ key_value.id ])
    expect(described_class.search(query: "/api/v1/app/performance_events").map { |row| row[:operational_log_event_id] }).to eq([ path.id ])
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

  it "does not trigger a rebuild when the local index already reflects the latest primary-DB event" do
    described_class.reset_freshness_check!
    recent = event(message: "already fresh", occurred_at: 1.minute.ago)
    described_class.upsert(recent)

    expect(upsert_query_count { described_class.search(since: 1.hour.ago) }).to eq(0)
  end

  it "self-heals a local index that fell behind the primary DB (e.g. a compute-tier worker that never runs indexing jobs)" do
    described_class.reset_freshness_check!
    stale_seed = event(message: "seeded at container boot", occurred_at: 50.minutes.ago)
    described_class.upsert(stale_seed)

    missed = event(message: "written elsewhere, never indexed on this host", occurred_at: 1.minute.ago)

    results = described_class.search(since: 1.hour.ago)

    expect(results.map { |row| row[:operational_log_event_id] }).to include(missed.id)
  end

  it "rebuilds in batched transactions instead of one transaction per row" do
    events = 3.times.map { |i| event(message: "event #{i}", occurred_at: (i + 1).minutes.ago) }

    transaction_count = 0
    callback = lambda do |_name, _started, _finished, _id, payload|
      transaction_count += 1 if payload[:name] == "TRANSACTION"
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      described_class.rebuild!
    end

    # One batch's worth of transaction notifications (begin + commit), not
    # one pair per row — a synchronous rebuild inside a search call (see
    # #ensure_fresh!) must not turn into one fsync per event on a busy
    # instance.
    expect(transaction_count).to be < events.size

    results = described_class.search(since: 1.hour.ago)
    expect(results.map { |row| row[:operational_log_event_id] }).to match_array(events.map(&:id))
  end

  it "only re-checks freshness once per FRESHNESS_CHECK_INTERVAL" do
    described_class.reset_freshness_check!
    event(message: "seed", occurred_at: 1.minute.ago)

    # The empty local index is stale relative to the seeded primary-DB event,
    # so the first search triggers exactly one rebuild (one upsert); the next
    # two searches happen inside the same freshness-check interval and must
    # not repeat it.
    expect(upsert_query_count { 3.times { described_class.search(since: 1.hour.ago) } }).to eq(1)
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

  def upsert_query_count
    count = 0
    callback = lambda do |_name, _started, _finished, _id, payload|
      count += 1 if payload[:name] == "OperationalLogIndex Upsert"
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    count
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
