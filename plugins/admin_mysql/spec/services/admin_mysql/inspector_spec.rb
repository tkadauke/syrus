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

  it "normalizes missing slow-log table permissions into actionable hints" do
    payload = described_class.new.send(
      :error_payload,
      StandardError.new("Mysql2::Error: SELECT command denied to user 'syrus' for table 'slow_log'")
    )

    expect(payload).to include(
      message: "The Syrus MySQL user cannot read mysql.slow_log.",
      hint: include("Grant SELECT")
    )
    expect(payload.fetch(:setup_sql)).to include(include("mysql.slow_log"))
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
    expect(rows.first).to include(command: "Query", info: "SELECT 2")
    expect(inspector).not_to have_received(:select_all).with(include("information_schema.PROCESSLIST"))
  end

  it "adds a per-statement timeout hint to expensive diagnostic SELECTs" do
    hinted = described_class.new.send(:mysql_timeout_hint, "SELECT * FROM mysql.slow_log", timeout_ms: 750)

    expect(hinted).to eq("SELECT /*+ MAX_EXECUTION_TIME(750) */ * FROM mysql.slow_log")
  end

  it "runs statement digest reads through the bounded diagnostic SELECT helper" do
    inspector = described_class.new
    allow(inspector).to receive(:connection).and_return(double(
      current_database: "syrus_production",
      quote: ->(value) { "'#{value}'" }
    ))
    allow(inspector).to receive(:select_all_with_timeout).and_return([])

    payload = inspector.send(:statement_digests, limit: 5)

    expect(payload).to include(available: true, rows: [])
    expect(inspector).to have_received(:select_all_with_timeout).with(include("events_statements_summary_by_digest"))
  end

  it "does not read slow-log rows unless explicitly requested" do
    inspector = described_class.new
    allow(inspector).to receive(:variables).and_return({
      "slow_query_log" => "ON",
      "log_output" => "TABLE",
      "long_query_time" => 1
    })
    allow(inspector).to receive(:slow_log_rows).and_return(available: true, rows: [ { sql_text: "SELECT 1" } ])

    payload = inspector.send(:slow_log, limit: 5, include_rows: false)

    expect(payload).to include(available: false, rows: [])
    expect(payload.dig(:error, :message)).to eq("slow-log rows are loaded on demand")
    expect(inspector).not_to have_received(:slow_log_rows)
  end

  it "reads slow-log rows when explicitly requested" do
    inspector = described_class.new
    allow(inspector).to receive(:variables).and_return({
      "slow_query_log" => "ON",
      "log_output" => "TABLE",
      "long_query_time" => 1
    })
    allow(inspector).to receive(:slow_log_rows).and_return(available: true, rows: [ { sql_text: "SELECT 1" } ])

    payload = inspector.send(:slow_log, limit: 5, include_rows: true)

    expect(payload).to include(available: true, rows: [ { sql_text: "SELECT 1" } ])
    expect(inspector).to have_received(:slow_log_rows).with(limit: 5)
  end

  it "bounds explicit slow-log reads to recent rows with a short timeout" do
    inspector = described_class.new
    connection = double(quote: "'2026-08-27 10:00:00'")
    allow(inspector).to receive(:variables).and_return({
      "slow_query_log" => "ON",
      "log_output" => "TABLE",
      "long_query_time" => 1
    })
    allow(inspector).to receive(:connection).and_return(connection)
    allow(inspector).to receive(:select_all_with_timeout).and_return([])

    expected_lookback = Time.zone.parse("2026-08-27 10:00:00 UTC")

    payload = freeze_time(Time.zone.parse("2026-08-27 12:00:00 UTC")) do
      inspector.send(:slow_log_rows, limit: 5)
    end

    expect(payload).to include(available: true, rows: [])
    expect(inspector).to have_received(:select_all_with_timeout).with(
      include("FROM mysql.slow_log", "WHERE start_time >=", "ORDER BY start_time DESC"),
      timeout_ms: 250
    )
    expect(connection).to have_received(:quote).with(expected_lookback)
  end
end
