require "rails_helper"

RSpec.describe MysqlDbBrowser::PermissionProvider do
  describe "query classification" do
    subject(:descriptor) { described_class.capability_descriptor("mysql.query/execute@v1") }

    {
      "SELECT email FROM users" => [ "mysql.query/read@v1", :medium ],
      "EXPLAIN SELECT email FROM users" => [ "mysql.query/read@v1", :medium ],
      "UPDATE users SET active = 0" => [ "mysql.query/write@v1", :high ],
      "ALTER TABLE users ADD archived_at datetime" => [ "mysql.query/schema_change@v1", :critical ],
      "GRANT ALL ON app.* TO operator" => [ "mysql.query/administer@v1", :critical ]
    }.each do |sql, (operation, risk)|
      it "classifies #{operation}" do
        result = Permissions::InvocationClassifier.call(descriptor:, arguments: { sql: sql })

        expect(result).to have_attributes(operation: operation, risk: risk, fallback?: false)
      end
    end

    it "falls back to the maximum risk for ambiguous statements" do
      result = Permissions::InvocationClassifier.call(descriptor:, arguments: { sql: "WITH rows AS (SELECT 1) UPDATE users SET active = 1" })

      expect(result).to have_attributes(
        operation: "mysql.query/execute@v1", risk: :critical, effects: descriptor.effects, fallback?: true
      )
    end

    it "falls back to the maximum risk when EXPLAIN ANALYZE could execute a mutation" do
      [
        "EXPLAIN ANALYZE DELETE FROM users WHERE active = 0",
        "EXPLAIN /* diagnostic */ ANALYZE UPDATE users SET active = 0"
      ].each do |sql|
        result = Permissions::InvocationClassifier.call(descriptor:, arguments: { sql: sql })

        expect(result).to have_attributes(
          operation: "mysql.query/execute@v1", risk: :critical, effects: descriptor.effects, fallback?: true
        )
      end
    end

    it "redacts SQL while retaining non-sensitive routing arguments" do
      expect(descriptor.redact(mysql_connection_id: 7, database: "app", sql: "SELECT 'secret'"))
        .to eq("mysql_connection_id" => 7, "database" => "app", "sql" => "[REDACTED SQL]")
    end

    it "normalizes equivalent whitespace to one fingerprint input" do
      first = Permissions::InvocationFingerprint.call(descriptor:, arguments: { sql: " SELECT  *\nFROM users ", mysql_connection_id: 7 })
      second = Permissions::InvocationFingerprint.call(descriptor:, arguments: { mysql_connection_id: 7, sql: "SELECT * FROM users" })

      expect(first).to eq(second)
    end
  end

  it "registers connection, database, table, query, schema, and administrative scopes" do
    expect(described_class.permission_resource_scopes.keys)
      .to contain_exactly(:connection, :database, :table, :query, :schema, :administrative)
  end

  it "compares global, connection, database, and table scopes hierarchically" do
    schema = described_class.permission_resource_scopes.fetch(:table)
    context = {}
    global = schema.normalize({}, context:).value
    connection = schema.normalize({ mysql_connection_id: 7 }, context:).value
    database = schema.normalize({ mysql_connection_id: 7, database: "app" }, context:).value
    table = schema.normalize({ mysql_connection_id: 7, database: "app", table: "users" }, context:).value

    expect(schema.compare(global, connection, context:).value).to eq(:broader)
    expect(schema.compare(connection, database, context:).value).to eq(:broader)
    expect(schema.compare(table, database, context:).value).to eq(:narrower)
    expect(schema.compare(table, { mysql_connection_id: 8 }, context:).value).to eq(:disjoint)
  end

  it "keeps read authority below query authority ceilings" do
    read = described_class.capability_descriptor("mysql.table/list@v1")
    query = described_class.capability_descriptor("mysql.query/execute@v1")

    expect(read).to have_attributes(maximum_autonomy: :job, risk: :medium)
    expect(query).to have_attributes(maximum_autonomy: :invocation, authority_durations: [ :invocation ], risk: :critical)
  end

  it "declares inert read-only and query-operator presets" do
    read_preset = described_class.permission_preset("mysql_read_only")
    query_preset = described_class.permission_preset("mysql_query_operator")

    expect(read_preset.render(subject_selector_type: "interactive_chat").map { |rule| rule.fetch("operation") })
      .to contain_exactly(*described_class::READ_OPERATIONS.keys)
    expect(query_preset.render(subject_selector_type: "interactive_chat").sole)
      .to include("operation" => "mysql.query/execute@v1", "policy" => "ask")
  end
end
