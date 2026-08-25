require "rails_helper"

RSpec.describe MysqlDbBrowser::SchemaInspector do
  def fake_client(rows_by_sql: {})
    client = instance_double(Mysql2::Client, close: nil)
    allow(client).to receive(:escape) { |value| value.to_s.gsub("'", "\\\\'") }
    allow(client).to receive(:query) do |sql|
      match = rows_by_sql.keys.find { |pattern| sql.match?(pattern) }
      raise "no stubbed rows for query: #{sql}" unless match

      rows_by_sql.fetch(match)
    end
    client
  end

  def stub_client_factory(client)
    original = described_class.client_factory
    described_class.client_factory = ->(**) { client }
    original
  end

  let(:connection) { Factories.mysql_connection(host: "db.internal", port: 3307, username: "app", password: "s3cret", default_database: "app_prod") }

  it "builds its Mysql2::Client from the connection's decrypted credentials, not ActiveRecord::Base.connection" do
    client = fake_client(rows_by_sql: { /information_schema\.SCHEMATA/ => [] })
    received_options = nil
    original = described_class.client_factory
    described_class.client_factory = lambda { |**opts|
      received_options = opts
      client
    }

    described_class.new(connection).databases

    expect(received_options).to include(host: "db.internal", port: 3307, username: "app", password: "s3cret", database: "app_prod")
  ensure
    described_class.client_factory = original
  end

  it "lists databases and flags the four MySQL system schemas alongside user databases" do
    client = fake_client(rows_by_sql: {
      /information_schema\.SCHEMATA/ => [
        { "SCHEMA_NAME" => "information_schema", "DEFAULT_CHARACTER_SET_NAME" => "utf8", "DEFAULT_COLLATION_NAME" => "utf8_general_ci" },
        { "SCHEMA_NAME" => "app_prod", "DEFAULT_CHARACTER_SET_NAME" => "utf8mb4", "DEFAULT_COLLATION_NAME" => "utf8mb4_0900_ai_ci" },
        { "SCHEMA_NAME" => "mysql", "DEFAULT_CHARACTER_SET_NAME" => "utf8", "DEFAULT_COLLATION_NAME" => "utf8_general_ci" },
        { "SCHEMA_NAME" => "performance_schema", "DEFAULT_CHARACTER_SET_NAME" => "utf8", "DEFAULT_COLLATION_NAME" => "utf8_general_ci" },
        { "SCHEMA_NAME" => "sys", "DEFAULT_CHARACTER_SET_NAME" => "utf8mb4", "DEFAULT_COLLATION_NAME" => "utf8mb4_0900_ai_ci" }
      ]
    })
    original = stub_client_factory(client)

    payload = described_class.new(connection).databases

    expect(payload[:available]).to be(true)
    system_flags = payload[:databases].to_h { |row| [ row[:name], row[:system_schema] ] }
    expect(system_flags).to eq(
      "information_schema" => true,
      "app_prod" => false,
      "mysql" => true,
      "performance_schema" => true,
      "sys" => true
    )
  ensure
    described_class.client_factory = original
  end

  it "lists tables for a database with approximate row counts and truncates when huge" do
    rows = (1..3).map { |i| { "TABLE_NAME" => "t#{i}", "TABLE_TYPE" => "BASE TABLE", "ENGINE" => "InnoDB", "TABLE_ROWS" => i * 100, "DATA_LENGTH" => 1024, "INDEX_LENGTH" => 512, "CREATE_TIME" => nil, "UPDATE_TIME" => nil, "TABLE_COMMENT" => "" } }
    client = fake_client(rows_by_sql: { /information_schema\.TABLES/ => rows })
    original = stub_client_factory(client)

    payload = described_class.new(connection).tables("app_prod")

    expect(payload).to include(available: true, database: "app_prod", system_schema: false, truncated: false)
    expect(payload[:tables].map { |t| t[:name] }).to eq(%w[t1 t2 t3])
    expect(payload[:tables].first).to include(approximate_row_count: 100, engine: "InnoDB")
  ensure
    described_class.client_factory = original
  end

  it "flags system schemas in the tables payload too" do
    client = fake_client(rows_by_sql: { /information_schema\.TABLES/ => [] })
    original = stub_client_factory(client)

    payload = described_class.new(connection).tables("mysql")

    expect(payload).to include(system_schema: true)
  ensure
    described_class.client_factory = original
  end

  it "degrades a denied tables query into an available:false section instead of raising" do
    client = instance_double(Mysql2::Client, close: nil)
    allow(client).to receive(:escape) { |value| value }
    allow(client).to receive(:query).and_raise(Mysql2::Error, "SELECT command denied to user 'app'@'%' for table 'TABLES'")
    original = stub_client_factory(client)

    payload = described_class.new(connection).tables("mysql")

    expect(payload[:available]).to be(false)
    expect(payload[:error]).to include(message: a_string_including("command denied"), hint: a_string_including("SELECT privileges"))
  ensure
    described_class.client_factory = original
  end

  it "returns table detail combining info, columns, and indexes" do
    client = fake_client(rows_by_sql: {
      /information_schema\.TABLES/ => [ { "TABLE_TYPE" => "BASE TABLE", "ENGINE" => "InnoDB", "TABLE_ROWS" => 42, "DATA_LENGTH" => 100, "INDEX_LENGTH" => 50, "AUTO_INCREMENT" => 43, "CREATE_TIME" => nil, "UPDATE_TIME" => nil, "TABLE_COLLATION" => "utf8mb4_0900_ai_ci", "TABLE_COMMENT" => "" } ],
      /information_schema\.COLUMNS/ => [
        { "COLUMN_NAME" => "id", "COLUMN_TYPE" => "bigint", "DATA_TYPE" => "bigint", "IS_NULLABLE" => "NO", "COLUMN_KEY" => "PRI", "COLUMN_DEFAULT" => nil, "EXTRA" => "auto_increment", "CHARACTER_MAXIMUM_LENGTH" => nil, "NUMERIC_PRECISION" => 20, "NUMERIC_SCALE" => 0, "COLUMN_COMMENT" => "" },
        { "COLUMN_NAME" => "email", "COLUMN_TYPE" => "varchar(255)", "DATA_TYPE" => "varchar", "IS_NULLABLE" => "YES", "COLUMN_KEY" => "", "COLUMN_DEFAULT" => nil, "EXTRA" => "", "CHARACTER_MAXIMUM_LENGTH" => 255, "NUMERIC_PRECISION" => nil, "NUMERIC_SCALE" => nil, "COLUMN_COMMENT" => "" }
      ],
      /information_schema\.STATISTICS/ => [
        { "INDEX_NAME" => "PRIMARY", "NON_UNIQUE" => 0, "SEQ_IN_INDEX" => 1, "COLUMN_NAME" => "id", "INDEX_TYPE" => "BTREE" },
        { "INDEX_NAME" => "index_users_on_email", "NON_UNIQUE" => 0, "SEQ_IN_INDEX" => 1, "COLUMN_NAME" => "email", "INDEX_TYPE" => "BTREE" }
      ],
      /information_schema\.KEY_COLUMN_USAGE/ => []
    })
    original = stub_client_factory(client)

    payload = described_class.new(connection).table("app_prod", "users")

    expect(payload[:database]).to eq("app_prod")
    expect(payload[:table]).to eq("users")
    expect(payload[:info]).to include(available: true, engine: "InnoDB", approximate_row_count: 42)
    expect(payload[:columns][:rows].map { |c| c[:name] }).to eq(%w[id email])
    expect(payload[:columns][:rows].first).to include(nullable: false, key: "PRI", extra: "auto_increment")
    expect(payload[:indexes][:rows]).to contain_exactly(
      include(name: "PRIMARY", unique: true, columns: [ "id" ]),
      include(name: "index_users_on_email", unique: true, columns: [ "email" ])
    )
    expect(payload[:foreign_keys]).to eq(available: true, truncated: false, rows: [])
  ensure
    described_class.client_factory = original
  end

  it "returns outgoing and incoming foreign keys, symmetric from_table/from_column -> to_table/to_column" do
    client = fake_client(rows_by_sql: {
      /information_schema\.TABLES/ => [ { "TABLE_TYPE" => "BASE TABLE", "ENGINE" => "InnoDB", "TABLE_ROWS" => 1, "DATA_LENGTH" => 1, "INDEX_LENGTH" => 1, "AUTO_INCREMENT" => nil, "CREATE_TIME" => nil, "UPDATE_TIME" => nil, "TABLE_COLLATION" => "utf8mb4_0900_ai_ci", "TABLE_COMMENT" => "" } ],
      /information_schema\.COLUMNS/ => [],
      /information_schema\.STATISTICS/ => [],
      /REFERENCED_TABLE_SCHEMA = 'app_prod' AND REFERENCED_TABLE_NAME = 'orders'/ => [
        { "CONSTRAINT_NAME" => "fk_payments_order", "TABLE_NAME" => "payments", "COLUMN_NAME" => "order_id", "REFERENCED_COLUMN_NAME" => "id" }
      ],
      /TABLE_SCHEMA = 'app_prod' AND TABLE_NAME = 'orders'/ => [
        { "CONSTRAINT_NAME" => "fk_orders_customer", "COLUMN_NAME" => "customer_id", "REFERENCED_TABLE_NAME" => "customers", "REFERENCED_COLUMN_NAME" => "id" }
      ]
    })
    original = stub_client_factory(client)

    payload = described_class.new(connection).table("app_prod", "orders")

    expect(payload[:foreign_keys][:available]).to be(true)
    expect(payload[:foreign_keys][:rows]).to contain_exactly(
      include(direction: "outgoing", from_table: "orders", from_column: "customer_id", to_table: "customers", to_column: "id"),
      include(direction: "incoming", from_table: "payments", from_column: "order_id", to_table: "orders", to_column: "id")
    )
  ensure
    described_class.client_factory = original
  end

  it "raises NotFound when the table does not exist in the given database" do
    client = fake_client(rows_by_sql: { /information_schema\.TABLES/ => [] })
    original = stub_client_factory(client)

    expect {
      described_class.new(connection).table("app_prod", "missing_table")
    }.to raise_error(described_class::NotFound, /missing_table/)
  ensure
    described_class.client_factory = original
  end

  it "raises Unavailable and still closes the client when the connection itself fails" do
    client = instance_double(Mysql2::Client, close: nil)
    allow(client).to receive(:query).and_raise(Mysql2::Error, "Access denied for user 'app'@'db.internal'")
    original = stub_client_factory(client)

    expect {
      described_class.new(connection).databases
    }.to raise_error(described_class::Unavailable, /Access denied/)
    expect(client).to have_received(:close)
  ensure
    described_class.client_factory = original
  end

  it "adds a per-query timeout hint to guard against a slow/unreachable host" do
    hinted = described_class.new(connection).send(:mysql_timeout_hint, "SELECT * FROM information_schema.TABLES")

    expect(hinted).to eq("SELECT /*+ MAX_EXECUTION_TIME(3000) */ * FROM information_schema.TABLES")
  end
end
