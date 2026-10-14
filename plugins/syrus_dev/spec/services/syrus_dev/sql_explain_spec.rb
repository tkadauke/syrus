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
end
