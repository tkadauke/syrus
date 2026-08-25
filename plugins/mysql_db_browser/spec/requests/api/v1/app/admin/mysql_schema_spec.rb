require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/mysql_connections/:id/schema", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }
  let(:connection) { Factories.mysql_connection(label: "Staging", password: "s3cret") }

  def parse_body = JSON.parse(response.body)

  def enable_plugin!
    Feature.find_or_create_by!(slug: "mysql_db_browser") { |f| f.category = "Labs"; f.name = "MySQL DB browser" }
      .update!(enabled: true)
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)
  end

  it "is disabled by default (feature flag off)" do
    sign_in_as(admin)
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)

    get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "rejects non-admins" do
    enable_plugin!
    sign_in_as(member)

    get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  describe "as an admin with the plugin enabled" do
    before do
      enable_plugin!
      sign_in_as(admin)
    end

    it "404s for an unknown connection id" do
      get "/api/v1/app/admin/mysql_connections/999999/schema"

      expect(response).to have_http_status(:not_found)
    end

    it "lists databases" do
      allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(
        instance_double(MysqlDbBrowser::SchemaInspector, databases: {
          available: true,
          generated_at: "2026-08-24T00:00:00Z",
          databases: [ { name: "app_prod", system_schema: false, default_character_set: "utf8mb4", default_collation: "utf8mb4_0900_ai_ci" } ]
        })
      )

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("databases", 0, "name")).to eq("app_prod")
    end

    it "reports a bad gateway when the connection is unavailable" do
      allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(
        instance_double(MysqlDbBrowser::SchemaInspector).tap do |inspector|
          allow(inspector).to receive(:databases).and_raise(MysqlDbBrowser::SchemaInspector::Unavailable, "Access denied")
        end
      )

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema"

      expect(response).to have_http_status(:bad_gateway)
      expect(parse_body.dig("error", "code")).to eq("connection_unavailable")
    end

    it "lists tables for a database" do
      allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(
        instance_double(MysqlDbBrowser::SchemaInspector, tables: {
          available: true,
          generated_at: "2026-08-24T00:00:00Z",
          database: "app_prod",
          system_schema: false,
          truncated: false,
          tables: [ { name: "users", type: "BASE TABLE", engine: "InnoDB", approximate_row_count: 10 } ]
        })
      )

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/tables"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("tables", 0, "name")).to eq("users")
    end

    it "returns table detail" do
      allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(
        instance_double(MysqlDbBrowser::SchemaInspector, table: {
          database: "app_prod",
          table: "users",
          system_schema: false,
          generated_at: "2026-08-24T00:00:00Z",
          info: { available: true, engine: "InnoDB" },
          columns: { available: true, truncated: false, rows: [ { name: "id" } ] },
          indexes: { available: true, truncated: false, rows: [] },
          foreign_keys: { available: true, truncated: false, rows: [] }
        })
      )

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/tables/users"

      expect(response).to have_http_status(:ok)
      expect(parse_body.dig("columns", "rows", 0, "name")).to eq("id")
    end

    it "404s when the requested table does not exist" do
      allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(
        instance_double(MysqlDbBrowser::SchemaInspector).tap do |inspector|
          allow(inspector).to receive(:table).and_raise(MysqlDbBrowser::SchemaInspector::NotFound, "Table app_prod.missing was not found")
        end
      )

      get "/api/v1/app/admin/mysql_connections/#{connection.id}/schema/app_prod/tables/missing"

      expect(response).to have_http_status(:not_found)
      expect(parse_body.dig("error", "code")).to eq("not_found")
    end
  end
end
