require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/mysql_connections/:id/query and .../content", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }
  let(:connection) { Factories.mysql_connection(label: "Staging", password: "s3cret") }

  def parse_body = JSON.parse(response.body)

  def enable_plugin!
    Feature.find_or_create_by!(slug: "mysql_db_browser") { |f| f.category = "Labs"; f.name = "MySQL DB browser" }
      .update!(enabled: true)
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)
  end

  def fake_result(rows)
    result = instance_double(Mysql2::Result, fields: rows.first&.keys || [])
    allow(result).to receive(:each) { |&block| rows.each(&block) }
    result
  end

  # For raw Query-tab statements: query() always returns the same rows
  # regardless of the SQL text.
  def fake_query_client(rows: [])
    client = instance_double(Mysql2::Client, close: nil)
    allow(client).to receive(:escape) { |value| value.to_s.gsub("'", "\\\\'") }
    allow(client).to receive(:query).and_return(fake_result(rows))
    client
  end

  # For the content-grid endpoint: query() must serve both the
  # SchemaInspector's information_schema introspection lookups (matched by
  # pattern) and the controller-built `` `db`.`table` `` SELECT.
  def fake_client(introspection_rows: {}, content_rows: [])
    content_result = fake_result(content_rows)

    client = instance_double(Mysql2::Client, close: nil)
    allow(client).to receive(:escape) { |value| value.to_s.gsub("\\") { "\\\\" }.gsub("'") { "\\'" } }
    allow(client).to receive(:query) do |sql, **_opts|
      if sql.match?(/FROM `/)
        content_result
      else
        match = introspection_rows.keys.find { |pattern| sql.match?(pattern) }
        raise "no stubbed rows for query: #{sql}" unless match

        introspection_rows.fetch(match)
      end
    end
    client
  end

  def stub_clients(client)
    MysqlDbBrowser::SchemaInspector.client_factory = ->(**) { client }
    MysqlDbBrowser::QueryExecutor.client_factory = ->(**) { client }
  end

  around do |example|
    original_schema_factory = MysqlDbBrowser::SchemaInspector.client_factory
    original_query_factory = MysqlDbBrowser::QueryExecutor.client_factory
    example.run
    MysqlDbBrowser::SchemaInspector.client_factory = original_schema_factory
    MysqlDbBrowser::QueryExecutor.client_factory = original_query_factory
  end

  describe "POST .../query" do
    it "rejects non-admins" do
      enable_plugin!
      sign_in_as(member)

      post "/api/v1/app/admin/mysql_connections/#{connection.id}/query", params: { mysql_query: { sql: "SELECT 1" } }

      expect(response).to have_http_status(:forbidden)
    end

    describe "as an admin with the plugin enabled" do
      before do
        enable_plugin!
        sign_in_as(admin)
      end

      it "executes a SELECT and audits it" do
        stub_clients(fake_query_client(rows: [ { "id" => 1 } ]))

        post "/api/v1/app/admin/mysql_connections/#{connection.id}/query", params: { mysql_query: { sql: "SELECT * FROM users" } }

        expect(response).to have_http_status(:ok)
        expect(parse_body["rows"]).to eq([ { "id" => 1 } ])
        expect(MysqlQueryAudit.last.user).to eq(admin)
      end

      it "rejects a write statement on a read-only connection with 403" do
        post "/api/v1/app/admin/mysql_connections/#{connection.id}/query", params: { mysql_query: { sql: "DELETE FROM users" } }

        expect(response).to have_http_status(:forbidden)
        expect(parse_body.dig("error", "code")).to eq("write_not_allowed")
      end

      it "allows a write statement once the connection opts in" do
        connection.update!(allow_writes: true)
        stub_clients(instance_double(Mysql2::Client, close: nil, affected_rows: 2, query: true))

        post "/api/v1/app/admin/mysql_connections/#{connection.id}/query", params: { mysql_query: { sql: "UPDATE users SET active = 1" } }

        expect(response).to have_http_status(:ok)
        expect(parse_body["affected_rows"]).to eq(2)
      end

      it "reports a bad gateway when the connection is unreachable" do
        MysqlDbBrowser::QueryExecutor.client_factory = ->(**) { raise Mysql2::Error, "Access denied" }

        post "/api/v1/app/admin/mysql_connections/#{connection.id}/query", params: { mysql_query: { sql: "SELECT 1" } }

        expect(response).to have_http_status(:bad_gateway)
        expect(parse_body.dig("error", "code")).to eq("connection_unavailable")
      end
    end
  end

  describe "GET .../schema/:database/tables/:table/content" do
    before do
      enable_plugin!
      sign_in_as(admin)
    end

    def table_introspection_rows
      {
        /information_schema\.TABLES/ => [ { "TABLE_TYPE" => "BASE TABLE", "ENGINE" => "InnoDB", "TABLE_ROWS" => 2, "DATA_LENGTH" => 1, "INDEX_LENGTH" => 1, "AUTO_INCREMENT" => nil, "CREATE_TIME" => nil, "UPDATE_TIME" => nil, "TABLE_COLLATION" => "utf8mb4_0900_ai_ci", "TABLE_COMMENT" => "" } ],
        /information_schema\.COLUMNS/ => [
          { "COLUMN_NAME" => "id", "COLUMN_TYPE" => "bigint", "DATA_TYPE" => "bigint", "IS_NULLABLE" => "NO", "COLUMN_KEY" => "PRI", "COLUMN_DEFAULT" => nil, "EXTRA" => "auto_increment", "CHARACTER_MAXIMUM_LENGTH" => nil, "NUMERIC_PRECISION" => 20, "NUMERIC_SCALE" => 0, "COLUMN_COMMENT" => "" },
          { "COLUMN_NAME" => "email", "COLUMN_TYPE" => "varchar(255)", "DATA_TYPE" => "varchar", "IS_NULLABLE" => "YES", "COLUMN_KEY" => "", "COLUMN_DEFAULT" => nil, "EXTRA" => "", "CHARACTER_MAXIMUM_LENGTH" => 255, "NUMERIC_PRECISION" => nil, "NUMERIC_SCALE" => nil, "COLUMN_COMMENT" => "" }
        ],
        /information_schema\.STATISTICS/ => [],
        /information_schema\.KEY_COLUMN_USAGE/ => []
      }
    end

    it "returns rows, columns, and a derived filter_schema for the table" do
      stub_clients(fake_client(introspection_rows: table_introspection_rows, content_rows: [ { "id" => 1, "email" => "a@example.com" } ]))

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/tables/users/content"

      expect(response).to have_http_status(:ok)
      expect(parse_body["rows"]).to eq([ { "id" => 1, "email" => "a@example.com" } ])
      expect(parse_body["filter_schema"].map { |f| f["field"] }).to contain_exactly("id", "email")
    end

    it "404s when the table does not exist" do
      stub_clients(fake_client(introspection_rows: { /information_schema\.TABLES/ => [] }))

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/tables/missing/content"

      expect(response).to have_http_status(:not_found)
    end

    it "applies an encoded filter tree to the generated WHERE clause" do
      client = fake_client(introspection_rows: table_introspection_rows, content_rows: [ { "id" => 1, "email" => "a@example.com" } ])
      stub_clients(client)
      q = Filters::QueryParam.encode({ "and" => [ { "field" => "email", "op" => "equals", "value" => "a@example.com" } ] })

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/tables/users/content", params: { q: q }

      expect(response).to have_http_status(:ok)
      expect(client).to have_received(:query).with(a_string_including("WHERE (`email` = 'a@example.com')"), any_args)
    end
  end

  describe "GET .../schema/:database/query_builder" do
    before do
      enable_plugin!
      sign_in_as(admin)
    end

    def orders_introspection_rows
      {
        /information_schema\.TABLES/ => [ { "TABLE_TYPE" => "BASE TABLE", "ENGINE" => "InnoDB", "TABLE_ROWS" => 2, "DATA_LENGTH" => 1, "INDEX_LENGTH" => 1, "AUTO_INCREMENT" => nil, "CREATE_TIME" => nil, "UPDATE_TIME" => nil, "TABLE_COLLATION" => "utf8mb4_0900_ai_ci", "TABLE_COMMENT" => "" } ],
        /information_schema\.COLUMNS/ => [
          { "COLUMN_NAME" => "id", "COLUMN_TYPE" => "bigint", "DATA_TYPE" => "bigint", "IS_NULLABLE" => "NO", "COLUMN_KEY" => "PRI", "COLUMN_DEFAULT" => nil, "EXTRA" => "auto_increment", "CHARACTER_MAXIMUM_LENGTH" => nil, "NUMERIC_PRECISION" => 20, "NUMERIC_SCALE" => 0, "COLUMN_COMMENT" => "" },
          { "COLUMN_NAME" => "status", "COLUMN_TYPE" => "varchar(20)", "DATA_TYPE" => "varchar", "IS_NULLABLE" => "YES", "COLUMN_KEY" => "", "COLUMN_DEFAULT" => nil, "EXTRA" => "", "CHARACTER_MAXIMUM_LENGTH" => 20, "NUMERIC_PRECISION" => nil, "NUMERIC_SCALE" => nil, "COLUMN_COMMENT" => "" }
        ],
        /information_schema\.STATISTICS/ => [],
        /information_schema\.KEY_COLUMN_USAGE/ => []
      }
    end

    it "compiles a plain column spec and runs it" do
      stub_clients(fake_client(introspection_rows: orders_introspection_rows, content_rows: [ { "id" => 1, "status" => "pending" } ]))
      spec = { table: "orders", columns: [ "orders.id", "orders.status" ] }.to_json

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/query_builder", params: { spec: spec }

      expect(response).to have_http_status(:ok)
      expect(parse_body["rows"]).to eq([ { "id" => 1, "status" => "pending" } ])
      expect(parse_body["filter_schema"].map { |f| f["field"] }).to contain_exactly("orders.id", "orders.status")
    end

    it "compiles a summarize (aggregate/group-by) spec" do
      client = fake_client(introspection_rows: orders_introspection_rows, content_rows: [ { "status" => "pending", "row_count" => 3 } ])
      stub_clients(client)
      spec = { table: "orders", aggregations: [ { function: "count", column: "*" } ], group_by: [ "orders.status" ] }.to_json

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/query_builder", params: { spec: spec }

      expect(response).to have_http_status(:ok)
      expect(client).to have_received(:query).with(a_string_including("GROUP BY `orders`.`status`"), any_args)
    end

    it "applies an encoded filter tree to the generated WHERE clause" do
      client = fake_client(introspection_rows: orders_introspection_rows, content_rows: [])
      stub_clients(client)
      spec = { table: "orders" }.to_json
      q = Filters::QueryParam.encode({ "and" => [ { "field" => "orders.status", "op" => "equals", "value" => "pending" } ] })

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/query_builder", params: { spec: spec, q: q }

      expect(response).to have_http_status(:ok)
      expect(client).to have_received(:query).with(a_string_including("WHERE (`orders`.`status` = 'pending')"), any_args)
    end

    it "returns invalid_spec for malformed JSON" do
      stub_clients(fake_client(introspection_rows: orders_introspection_rows))

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/query_builder", params: { spec: "not json" }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_spec")
    end

    it "returns invalid_spec (not a 500) when the top-level spec JSON is an array" do
      stub_clients(fake_client(introspection_rows: orders_introspection_rows))

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/query_builder", params: { spec: [ 1, 2, 3 ].to_json }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_spec")
    end

    it "returns invalid_spec (not a 500) when join is a string instead of an object" do
      stub_clients(fake_client(introspection_rows: orders_introspection_rows))
      spec = { table: "orders", join: "customers" }.to_json

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/query_builder", params: { spec: spec }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_spec")
    end

    it "returns invalid_spec (not a 500) when an aggregation entry is a string instead of an object" do
      stub_clients(fake_client(introspection_rows: orders_introspection_rows))
      spec = { table: "orders", aggregations: [ "count(*)" ] }.to_json

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/query_builder", params: { spec: spec }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_spec")
    end

    it "returns invalid_spec when the spec references an unknown column" do
      stub_clients(fake_client(introspection_rows: orders_introspection_rows))
      spec = { table: "orders", columns: [ "orders.nope" ] }.to_json

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/query_builder", params: { spec: spec }

      expect(response).to have_http_status(:unprocessable_content)
      expect(parse_body.dig("error", "code")).to eq("invalid_spec")
    end

    it "404s when the base table does not exist" do
      stub_clients(fake_client(introspection_rows: { /information_schema\.TABLES/ => [] }))
      spec = { table: "missing" }.to_json

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/query_builder", params: { spec: spec }

      expect(response).to have_http_status(:not_found)
    end
  end
end
