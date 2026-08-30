require "rails_helper"

RSpec.describe MysqlDbBrowser::QueryExecutor do
  let(:connection) { Factories.mysql_connection(host: "db.internal", port: 3307, username: "app", password: "s3cret", default_database: "app_prod") }
  let(:user) { Factories.user }

  def fake_client(rows: [], columns: nil, affected_rows: 0, escape: ->(value) { value.to_s.gsub("'", "\\\\'") })
    result = instance_double(Mysql2::Result, fields: columns || rows.first&.keys || [])
    allow(result).to receive(:each) { |&block| rows.each(&block) }

    client = instance_double(Mysql2::Client, close: nil, affected_rows: affected_rows)
    allow(client).to receive(:escape, &escape)
    allow(client).to receive(:query).and_return(result)
    allow(client).to receive(:abandon_results!)
    client
  end

  def stub_client_factory(client)
    original = described_class.client_factory
    described_class.client_factory = ->(**) { client }
    original
  end

  around do |example|
    original = described_class.client_factory
    example.run
    described_class.client_factory = original
  end

  describe "#execute" do
    it "runs a SELECT, truncates to the row limit, and audits the attempt" do
      rows = [ { "id" => 1, "email" => "a@example.com" }, { "id" => 2, "email" => "b@example.com" } ]
      stub_client_factory(fake_client(rows: rows))

      payload = described_class.new(connection).execute("SELECT * FROM users", user: user, limit: 10)

      expect(payload[:available]).to be(true)
      expect(payload[:rows]).to eq(rows)
      expect(payload[:row_count]).to eq(2)
      expect(payload[:truncated]).to be(false)
      expect(payload[:read_only]).to be(true)

      audit = MysqlQueryAudit.last
      expect(audit.mysql_connection).to eq(connection)
      expect(audit.user).to eq(user)
      expect(audit.statement).to eq("SELECT * FROM users")
      expect(audit.success).to be(true)
      expect(audit.row_count).to eq(2)
    end

    it "clamps to the requested limit and reports truncated when more rows exist" do
      rows = (1..5).map { |i| { "id" => i } }
      stub_client_factory(fake_client(rows: rows))

      payload = described_class.new(connection).execute("SELECT * FROM users", user: user, limit: 3)

      expect(payload[:rows].length).to eq(3)
      expect(payload[:row_count]).to eq(3)
      expect(payload[:truncated]).to be(true)
    end

    it "rejects non-SELECT statements on a read-only connection without opening a connection" do
      described_class.client_factory = ->(**) { raise "should not connect" }

      expect {
        described_class.new(connection).execute("DELETE FROM users", user: user)
      }.to raise_error(described_class::WriteNotAllowed)

      audit = MysqlQueryAudit.last
      expect(audit.success).to be(false)
      expect(audit.read_only).to be(false)
      expect(audit.error_message).to include("read-only")
    end

    it "allows writes once the connection opts in" do
      connection.update!(allow_writes: true)
      stub_client_factory(fake_client(affected_rows: 4))

      payload = described_class.new(connection).execute("DELETE FROM users WHERE id = 1", user: user)

      expect(payload[:available]).to be(true)
      expect(payload[:affected_rows]).to eq(4)
      expect(payload[:read_only]).to be(false)
    end

    it "raises Unavailable and still audits nothing extra when the connection itself fails" do
      original = described_class.client_factory
      described_class.client_factory = ->(**) { raise Mysql2::Error, "Access denied for user 'app'@'db.internal'" }

      expect {
        described_class.new(connection).execute("SELECT 1", user: user)
      }.to raise_error(described_class::Unavailable, /Access denied/)
    ensure
      described_class.client_factory = original
    end

    it "degrades a query-time error into an available:false payload instead of raising, and audits the failure" do
      client = instance_double(Mysql2::Client, close: nil)
      allow(client).to receive(:query).and_raise(Mysql2::Error, "You have an error in your SQL syntax")
      stub_client_factory(client)

      payload = described_class.new(connection).execute("SELECT * FROM", user: user)

      expect(payload[:available]).to be(false)
      expect(payload[:error]).to include(message: a_string_including("syntax"))

      audit = MysqlQueryAudit.last
      expect(audit.success).to be(false)
      expect(audit.error_message).to include("syntax")
    end

    it "raises BlankStatement for an empty SQL string" do
      expect {
        described_class.new(connection).execute("   ", user: user)
      }.to raise_error(described_class::BlankStatement)
    end

    it "truncates long string values using safe_byteslice" do
      long_value = "x" * 3_000
      stub_client_factory(fake_client(rows: [ { "note" => long_value } ]))

      payload = described_class.new(connection).execute("SELECT note FROM notes", user: user)

      expect(payload[:rows].first["note"].bytesize).to be <= described_class::MAX_VALUE_BYTES + "…".bytesize
      expect(payload[:rows].first["note"]).to end_with("…")
    end

    it "adds a MAX_EXECUTION_TIME hint to SELECT statements but not to WITH ... CTEs" do
      client = fake_client(rows: [])
      stub_client_factory(client)
      executor = described_class.new(connection)

      executor.execute("SELECT * FROM users", user: user)
      expect(client).to have_received(:query).with(a_string_starting_with("SELECT /*+ MAX_EXECUTION_TIME("), any_args)

      executor.execute("WITH t AS (SELECT 1) SELECT * FROM t", user: user)
      expect(client).to have_received(:query).with("WITH t AS (SELECT 1) SELECT * FROM t", any_args)
    end

    it "treats SHOW and DESCRIBE statements as read-only diagnostics" do
      client = fake_client(rows: [ { "Name" => "users" } ])
      stub_client_factory(client)
      executor = described_class.new(connection)

      show_payload = executor.execute("SHOW TABLES", user: user)
      describe_payload = executor.execute("DESCRIBE users", user: user)

      expect(show_payload[:read_only]).to be(true)
      expect(describe_payload[:read_only]).to be(true)
      expect(client).to have_received(:query).with("SHOW TABLES", any_args)
      expect(client).to have_received(:query).with("DESCRIBE users", any_args)
    end

    it "treats EXPLAIN diagnostics as read-only and audits them without requiring write access" do
      client = fake_client(rows: [ { "select_type" => "SIMPLE", "table" => "users" } ])
      stub_client_factory(client)

      payload = described_class.new(connection).execute("EXPLAIN SELECT * FROM users", user: user)

      expect(payload[:read_only]).to be(true)
      expect(client).to have_received(:query).with("EXPLAIN SELECT * FROM users", any_args)

      audit = MysqlQueryAudit.last
      expect(audit.statement).to eq("EXPLAIN SELECT * FROM users")
      expect(audit.read_only).to be(true)
      expect(audit.success).to be(true)
    end

    it "allows EXPLAIN ANALYZE for read statements but still rejects unrelated non-read statements" do
      client = fake_client(rows: [ { "EXPLAIN" => "-> Table scan on users" } ])
      stub_client_factory(client)

      payload = described_class.new(connection).execute("EXPLAIN ANALYZE SELECT * FROM users", user: user)

      expect(payload[:read_only]).to be(true)
      expect(client).to have_received(:query).with("EXPLAIN ANALYZE SELECT * FROM users", any_args)

      expect {
        described_class.new(connection).execute("EXPLAIN CONNECTION 12", user: user)
      }.to raise_error(described_class::WriteNotAllowed)

      expect {
        described_class.new(connection).execute("EXPLAIN ANALYZE UPDATE users SET name = 'x'", user: user)
      }.to raise_error(described_class::WriteNotAllowed)
    end
  end

  describe "#execute_select" do
    it "yields the connected client so the caller can build a SQL string with the same escaper" do
      rows = [ { "id" => 1 } ]
      client = fake_client(rows: rows)
      stub_client_factory(client)
      received_client = nil

      payload = described_class.new(connection).execute_select(user: user) do |yielded_client|
        received_client = yielded_client
        "SELECT * FROM users"
      end

      expect(received_client).to eq(client)
      expect(payload[:available]).to be(true)
      expect(payload[:read_only]).to be(true)
    end
  end
end
