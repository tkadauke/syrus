require "rails_helper"

RSpec.describe AdminMysql::Inspector do
  it "reports unavailable when the Rails adapter is not mysql2" do
    expect(described_class.mysql?).to be(false)

    expect {
      described_class.new.snapshot
    }.to raise_error(described_class::Unavailable, /mysql2 adapter/)
  end

  it "normalizes missing Performance Schema permissions into actionable hints" do
    payload = described_class.new.send(
      :error_payload,
      StandardError.new("Mysql2::Error: SELECT command denied to user 'syrus' for table 'events_statements_summary_by_digest'")
    )

    expect(payload).to include(
      message: "The Syrus MySQL user cannot read Performance Schema statement digests.",
      hint: include("Grant SELECT")
    )
    expect(payload.fetch(:setup_sql)).to include(include("performance_schema.events_statements_summary_by_digest"))
  end

  describe "storage and DDL progress" do
    let(:inspector) { described_class.new }
    let(:connection) { double("connection", current_database: "syrus_production") }

    before do
      allow(connection).to receive(:quote) { |value| "'#{value}'" }
      allow(inspector).to receive(:connection).and_return(connection)
    end

    it "reports progress and remaining time for a running index build" do
      allow(inspector).to receive(:select_all).and_return(
        [ { "NAME" => "stage/innodb/alter table (read PK and internal sort)", "ENABLED" => "YES" } ],
        [ { "NAME" => "events_stages_current", "ENABLED" => "YES" } ]
      )
      allow(inspector).to receive(:select_all_with_timeout).and_return([
        { "PROCESSLIST_ID" => 17413, "EVENT_NAME" => "stage/innodb/alter table (read PK and internal sort)",
          "WORK_COMPLETED" => 250, "WORK_ESTIMATED" => 1000 }
      ])
      processes = [ { id: 17413, time_seconds: 300, info: "CREATE INDEX idx ON test_insight_cases (a)" } ]

      progress = inspector.send(:ddl_progress, processes)

      expect(progress[:available]).to be(true)
      expect(progress[:rows].first).to include(
        thread_id: 17413, percent_complete: 25.0, elapsed_seconds: 300,
        estimated_remaining_seconds: 900, statement: include("CREATE INDEX")
      )
    end

    it "says how to enable progress instead of reporting no DDL when the instruments are off" do
      allow(inspector).to receive(:select_all).and_return(
        [ { "NAME" => "stage/innodb/alter table (read PK and internal sort)", "ENABLED" => "NO" } ],
        [ { "NAME" => "events_stages_current", "ENABLED" => "NO" } ]
      )

      progress = inspector.send(:ddl_progress, [])

      expect(progress[:available]).to be(false)
      expect(progress[:error][:message]).to include("events_stages_current")
      expect(progress[:error][:setup_sql]).to include(include("setup_instruments"), include("setup_consumers"))
    end

    it "lists the largest tables with data and index sizes" do
      allow(inspector).to receive(:select_all_with_timeout).and_return([
        { "TABLE_NAME" => "test_insight_cases", "ENGINE" => "InnoDB", "TABLE_ROWS" => 42_000_000,
          "DATA_LENGTH" => 9_000, "INDEX_LENGTH" => 1_000, "DATA_FREE" => 5 }
      ])

      storage = inspector.send(:storage, limit: 10)

      expect(storage).to include(available: true, approximate: true)
      expect(storage[:tables].first).to eq(
        table: "test_insight_cases", engine: "InnoDB", estimated_rows: 42_000_000,
        data_bytes: 9_000, index_bytes: 1_000, total_bytes: 10_000, free_bytes: 5
      )
      expect(inspector).to have_received(:select_all_with_timeout).with(include("TABLE_SCHEMA = 'syrus_production'"))
    end
  end

  it "builds the process list from SHOW FULL PROCESSLIST without aggregating information_schema" do
    inspector = described_class.new
    allow(inspector).to receive(:select_all).with("SHOW FULL PROCESSLIST").and_return([
      { "Id" => 7, "User" => "syrus", "Host" => "web", "db" => "syrus", "Command" => "Sleep", "Time" => 900, "State" => nil, "Info" => nil },
      { "Id" => 4, "User" => "syrus", "Host" => "worker", "db" => "syrus", "Command" => "Query", "Time" => 10, "State" => "executing", "Info" => "SELECT 1" },
      { "Id" => 5, "User" => "syrus", "Host" => "worker", "db" => "syrus", "Command" => "Query", "Time" => 30, "State" => "executing", "Info" => "SELECT 2" }
    ])

    rows = inspector.send(:process_list, limit: 2)

    expect(rows.map { |row| row[:id] }).to eq([ 5, 4 ])
    expect(rows.first).to include(command: "Query", info: "SELECT ?")
    expect(rows).to all(satisfy { |row| !row.key?(:statement_verifier) })
    expect(inspector).not_to have_received(:select_all).with(include("information_schema.PROCESSLIST"))
  end

  it "reports sleeping connections when idle process rows are omitted" do
    inspector = described_class.new
    allow(described_class).to receive(:mysql?).and_return(true)
    allow(inspector).to receive(:process_list).with(limit: 50, include_idle: false).and_return([])
    allow(inspector).to receive(:status_hash).and_return({
      "Threads_connected" => 10,
      "Threads_running" => 2,
      "Max_used_connections" => 20,
      "Aborted_connects" => 0,
      "Connection_errors_max_connections" => 0
    })
    allow(inspector).to receive(:variable_hash).and_return({
      "max_connections" => 200,
      "wait_timeout" => 28_800,
      "interactive_timeout" => 28_800
    })

    payload = inspector.snapshot(sections: [ "live" ])

    expect(payload.fetch(:process_list)).to be_empty
    expect(payload.fetch(:connection_summary)).to include(
      threads_connected: 10,
      threads_running: 2,
      sleeping_connections: 8
    )
  end

  it "redacts literals from process-list and slow-log SQL" do
    inspector = described_class.new
    sql = "SELECT * FROM users WHERE email = 'person@example.com' AND attempts = 12 AND token = 0xdeadbeef"

    expect(inspector.send(:redact_sql, sql)).to eq(
      "SELECT * FROM users WHERE email = ? AND attempts = ? AND token = ?"
    )
  end

  it "redacts literals when looking up one process for a pending kill action" do
    inspector = described_class.new
    allow(described_class).to receive(:mysql?).and_return(true)
    allow(inspector).to receive(:select_all).with("SHOW FULL PROCESSLIST").and_return([
      { "Id" => 42, "User" => "syrus", "Host" => "worker", "db" => "syrus", "Command" => "Query", "Time" => 3,
        "State" => "executing", "Info" => "SELECT * FROM users WHERE token = 'top-secret'" }
    ])

    process = inspector.process(42)
    expect(process).to include(
      id: 42,
      info: "SELECT * FROM users WHERE token = ?",
      statement_verifier: match(/\A[0-9a-f]{64}\z/)
    )
    expect(process[:statement_verifier]).not_to eq(Digest::SHA256.hexdigest("SELECT * FROM users WHERE token = 'top-secret'"))
  end

  it "redacts string literals truncated by the diagnostic limit" do
    inspector = described_class.new

    redacted = inspector.send(:redact_sql, "SELECT '#{"sensitive" * 200}'")

    expect(redacted).to eq("SELECT ?")
  end

  it "parses string thread ids as decimal and rejects non-decimal forms" do
    inspector = described_class.new
    connection = double(execute: true)
    allow(described_class).to receive(:mysql?).and_return(true)
    allow(inspector).to receive(:connection).and_return(connection)

    expect(inspector.kill_query("010")).to include(killed: true, thread_id: 10)
    expect(connection).to have_received(:execute).with("KILL QUERY 10")
    expect { inspector.kill_query("0x10") }.to raise_error(ArgumentError, /positive decimal integer/)
  end

  it "revalidates the captured statement before killing a query" do
    inspector = described_class.new
    connection = spy
    allow(described_class).to receive(:mysql?).and_return(true)
    allow(inspector).to receive(:connection).and_return(connection)
    allow(inspector).to receive(:select_all).with("SHOW FULL PROCESSLIST").and_return([
      { "Id" => 42, "User" => "syrus", "Host" => "worker", "db" => "syrus", "Command" => "Query", "Time" => 1, "State" => "executing", "Info" => "UPDATE jobs SET state = 'running'" }
    ])

    expect {
      inspector.kill_query(42, expected_statement: "SELECT * FROM jobs")
    }.to raise_error(ArgumentError, /different statement/)
    expect(connection).not_to have_received(:execute)
  end

  it "uses a keyed verifier to detect changes between statements with identical redaction" do
    inspector = described_class.new
    connection = spy
    allow(described_class).to receive(:mysql?).and_return(true)
    allow(inspector).to receive(:connection).and_return(connection)
    allow(inspector).to receive(:select_all).with("SHOW FULL PROCESSLIST").and_return([
      { "Id" => 42, "User" => "syrus", "Host" => "worker", "db" => "syrus", "Command" => "Query", "Time" => 1,
        "State" => "executing", "Info" => "UPDATE jobs SET state = 'failed'" }
    ])

    expect {
      inspector.kill_query(
        42,
        expected_statement: "UPDATE jobs SET state = ?",
        expected_statement_verifier: inspector.send(:statement_verifier, "UPDATE jobs SET state = 'running'")
      )
    }.to raise_error(ArgumentError, /different statement/)
    expect(connection).not_to have_received(:execute)
  end

  it "adds a per-statement timeout hint to expensive diagnostic SELECTs" do
    hinted = described_class.new.send(:mysql_timeout_hint, "SELECT * FROM performance_schema.global_status", timeout_ms: 750)

    expect(hinted).to eq("SELECT /*+ MAX_EXECUTION_TIME(750) */ * FROM performance_schema.global_status")
  end

  it "runs statement digest reads through the bounded diagnostic SELECT helper" do
    inspector = described_class.new
    allow(inspector).to receive(:connection).and_return(double(
      current_database: "syrus_production",
      quote: ->(value) { "'#{value}'" }
    ))
    allow(inspector).to receive(:select_all_with_timeout).and_return([
      { "SCHEMA_NAME" => "syrus_production", "DIGEST_TEXT" => "SELECT * FROM jobs WHERE id = ?", "COUNT_STAR" => 3,
        "total_seconds" => "1.5", "avg_seconds" => "0.5", "max_seconds" => "0.8", "SUM_ROWS_SENT" => 3,
        "SUM_ROWS_EXAMINED" => 30, "FIRST_SEEN" => nil, "LAST_SEEN" => nil }
    ])

    payload = inspector.send(:statement_digests, limit: 5)

    expect(payload).to include(available: true)
    expect(payload.fetch(:rows).first).to include(count: 3, total_seconds: 1.5, avg_seconds: 0.5, rows_examined: 30)
    expect(inspector).to have_received(:select_all_with_timeout).with(include("events_statements_summary_by_digest"))
  end

  it "returns recent Syrus slow-SQL events with calling context" do
    inspector = described_class.new
    allow(Syrus::Host::PerformanceLogging).to receive(:recent_slow_sql).with(limit: 5).and_return([
      { "occurred_at" => "2026-11-28T10:00:00Z", "duration_ms" => 420.5,
        "sql" => "SELECT * FROM jobs WHERE id = 42", "controller" => "Api::JobsController", "action" => "show" }
    ])

    payload = inspector.send(:slow_sql_events, limit: 5)

    expect(payload).to include(available: true)
    expect(payload.fetch(:rows).first).to include(
      duration_ms: 420.5, sql: "SELECT * FROM jobs WHERE id = ?", controller: "Api::JobsController", action: "show"
    )
  end

  it "degrades recent slow-SQL event failures to an unavailable section" do
    inspector = described_class.new
    allow(Syrus::Host::PerformanceLogging).to receive(:recent_slow_sql).and_raise("event store unavailable")

    expect(inspector.send(:slow_sql_events, limit: 5)).to include(
      available: false, rows: [], error: include(message: "event store unavailable")
    )
  end
end
