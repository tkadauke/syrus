require "rails_helper"

RSpec.describe MysqlDbBrowser::ListTablesTool do
  let(:connection) { Factories.mysql_connection(agentic_access_enabled: true) }

  def call(mysql_connection_id:, database:)
    described_class.call(server_context: {}, mysql_connection_id: mysql_connection_id, database: database)
  end

  it "returns the database's tables payload" do
    payload = { available: true, database: "app_prod", tables: [ { name: "users" } ] }
    inspector = instance_double(MysqlDbBrowser::SchemaInspector, tables: payload)
    allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(inspector)

    response = call(mysql_connection_id: connection.id, database: "app_prod")

    expect(response.error?).to be(false)
    expect(inspector).to have_received(:tables).with("app_prod")
    expect(JSON.parse(response.content.first[:text], symbolize_names: true)).to eq(payload)
  end

  it "surfaces a degraded (available: false) payload as an error response" do
    payload = { available: false, error: { class: "Mysql2::Error", message: "command denied" } }
    allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(instance_double(MysqlDbBrowser::SchemaInspector, tables: payload))

    response = call(mysql_connection_id: connection.id, database: "app_prod")

    expect(response.error?).to be(true)
  end

  it "refuses when the connection has agentic access disabled" do
    disabled = Factories.mysql_connection(agentic_access_enabled: false)

    response = call(mysql_connection_id: disabled.id, database: "app_prod")

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end
end
