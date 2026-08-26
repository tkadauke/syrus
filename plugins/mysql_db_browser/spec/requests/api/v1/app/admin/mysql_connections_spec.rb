require "rails_helper"

RSpec.describe "API: /api/v1/app/admin/mysql_connections", type: :request do
  let!(:admin) { Factories.user(admin: true) }
  let(:member) { Factories.user(admin: false) }

  def parse_body = JSON.parse(response.body)

  def enable_plugin!
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)
  end

  it "is disabled by default (plugin disabled)" do
    sign_in_as(admin)

    get "/api/v1/app/admin/mysql_connections"

    expect(response).to have_http_status(:not_found)
    expect(parse_body.dig("error", "code")).to eq("plugin_disabled")
  end

  it "rejects non-admins" do
    enable_plugin!
    sign_in_as(member)

    get "/api/v1/app/admin/mysql_connections"

    expect(response).to have_http_status(:forbidden)
    expect(parse_body.dig("error", "code")).to eq("forbidden")
  end

  describe "as an admin with the plugin enabled" do
    before do
      enable_plugin!
      sign_in_as(admin)
    end

    it "lists connections without exposing plaintext credentials" do
      Factories.mysql_connection(label: "Staging", password: "s3cret")

      get "/api/v1/app/admin/mysql_connections"

      expect(response).to have_http_status(:ok)
      connection = parse_body.fetch("mysql_connections").first
      expect(connection["label"]).to eq("Staging")
      expect(connection["has_password"]).to be(true)
      expect(connection).not_to have_key("password")
      expect(connection).not_to have_key("credentials")
      expect(response.body).not_to include("s3cret")
    end

    it "creates a connection with encrypted credentials" do
      post "/api/v1/app/admin/mysql_connections", params: {
        mysql_connection: {
          label: "Prod", host: "db.example.com", port: 3306, username: "app", password: "hunter2"
        }
      }

      expect(response).to have_http_status(:created)
      expect(response.body).not_to include("hunter2")

      connection = MysqlConnection.find(parse_body.dig("mysql_connection", "id"))
      expect(connection.password).to eq("hunter2")
      expect(connection.agentic_access_enabled).to be false
    end

    it "rejects invalid params" do
      post "/api/v1/app/admin/mysql_connections", params: { mysql_connection: { label: "", host: "", username: "" } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(MysqlConnection.count).to eq(0)
    end

    it "updates a connection, optionally rotating the password" do
      connection = Factories.mysql_connection(password: "old-pass")

      patch "/api/v1/app/admin/mysql_connections/#{connection.id}", params: {
        mysql_connection: { label: "Renamed", password: "new-pass" }
      }

      expect(response).to have_http_status(:ok)
      connection.reload
      expect(connection.label).to eq("Renamed")
      expect(connection.password).to eq("new-pass")
    end

    it "leaves the password untouched when not supplied on update" do
      connection = Factories.mysql_connection(password: "keep-me")

      patch "/api/v1/app/admin/mysql_connections/#{connection.id}", params: { mysql_connection: { label: "Renamed" } }

      expect(response).to have_http_status(:ok)
      expect(connection.reload.password).to eq("keep-me")
    end

    it "deletes a connection" do
      connection = Factories.mysql_connection

      delete "/api/v1/app/admin/mysql_connections/#{connection.id}"

      expect(response).to have_http_status(:no_content)
      expect(MysqlConnection.where(id: connection.id)).not_to exist
    end

    describe "test_connection" do
      it "reports success without persisting a draft connection" do
        allow(MysqlDbBrowser::ConnectionTester).to receive(:test_params).and_return({ success: true })

        expect {
          post "/api/v1/app/admin/mysql_connections/test", params: {
            mysql_connection: { label: "Draft", host: "db.example.com", port: 3306, username: "app", password: "x" }
          }
        }.not_to change(MysqlConnection, :count)

        expect(response).to have_http_status(:ok)
        expect(parse_body["success"]).to be(true)
      end

      it "reports failure without persisting anything" do
        allow(MysqlDbBrowser::ConnectionTester).to receive(:test_params).and_return({ success: false, error: "Access denied" })

        expect {
          post "/api/v1/app/admin/mysql_connections/test", params: {
            mysql_connection: { label: "Draft", host: "db.example.com", port: 3306, username: "app", password: "wrong" }
          }
        }.not_to change(MysqlConnection, :count)

        expect(response).to have_http_status(:ok)
        expect(parse_body["success"]).to be(false)
        expect(parse_body["error"]).to eq("Access denied")
      end

      it "tests an existing connection using its stored credentials" do
        connection = Factories.mysql_connection(password: "stored-pass")
        allow(MysqlDbBrowser::ConnectionTester).to receive(:test_params)
          .with(hash_including(password: "stored-pass"))
          .and_return({ success: true })

        post "/api/v1/app/admin/mysql_connections/#{connection.id}/test"

        expect(response).to have_http_status(:ok)
        expect(parse_body["success"]).to be(true)
      end
    end
  end
end
