require "rails_helper"

RSpec.describe SyrusDev::SqlExplain do
  it "wraps database explain failures in a user-facing error" do
    connection = ActiveRecord::Base.connection
    database_error = ActiveRecord::StatementInvalid.new("Mysql2::Error: You have an error in your SQL syntax")

    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
    allow(connection).to receive(:select_all).and_raise(database_error)

    expect {
      described_class.call(sql: "SELECT * FROM missing_table")
    }.to raise_error(described_class::Error, /stored sample SQL may be truncated/) { |error|
      expect(error.cause).to eq(database_error)
    }
  end

  it "rejects MySQL clauses and functions that are unsafe for EXPLAIN ANALYZE" do
    expect {
      described_class.call(sql: "SELECT SLEEP(1)", analyze: true)
    }.to raise_error(described_class::Error, /not safe for EXPLAIN ANALYZE/)

    expect {
      described_class.call(sql: "SELECT * FROM users FOR SHARE", analyze: true)
    }.to raise_error(described_class::Error, /not safe for EXPLAIN ANALYZE/)
  end

  it "does not classify text in literals, quoted identifiers, or comments as executable SQL" do
    connection = instance_double(
      ActiveRecord::ConnectionAdapters::AbstractAdapter,
      adapter_name: "Mysql2"
    )
    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
    allow(connection).to receive(:execute)
    allow(connection).to receive(:select_all).and_return(ActiveRecord::Result.new([], []))

    harmless_queries = [
      "SELECT 'update; sleep(1)' AS status",
      "SELECT `delete` FROM users",
      "SELECT 1 /* update; SLEEP(1) */",
      "SELECT 1 -- delete; SLEEP(1)\n"
    ]

    harmless_queries.each do |sql|
      expect { described_class.call(sql: sql, analyze: true) }.not_to raise_error
    end
  end

  it "still rejects executable mutating keywords, unsafe functions, and multiple statements" do
    expect {
      described_class.call(sql: "WITH changed AS (DELETE FROM users RETURNING *) SELECT * FROM changed")
    }.to raise_error(described_class::Error, /non-read-only SQL/)

    expect {
      described_class.call(sql: "SELECT 1; DELETE FROM users")
    }.to raise_error(described_class::Error, /single statement/)

    expect {
      described_class.call(sql: "SELECT /* harmless */ SLEEP(1)", analyze: true)
    }.to raise_error(described_class::Error, /not safe for EXPLAIN ANALYZE/)

    expect {
      described_class.call(sql: "SELECT 1 /*!; DELETE FROM users */")
    }.to raise_error(described_class::Error, /executable comments/)
  end
end
