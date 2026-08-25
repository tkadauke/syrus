require "rails_helper"

RSpec.describe MysqlDbBrowser::DescribeTableTool do
  let(:connection) { Factories.mysql_connection(agentic_access_enabled: true) }

  def call(mysql_connection_id:, database:, table:)
    described_class.call(server_context: {}, mysql_connection_id: mysql_connection_id, database: database, table: table)
  end

  it "returns the table's detail payload" do
    payload = { database: "app_prod", table: "users", columns: { available: true, rows: [] } }
    inspector = instance_double(MysqlDbBrowser::SchemaInspector, table: payload)
    allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(inspector)

    response = call(mysql_connection_id: connection.id, database: "app_prod", table: "users")

    expect(response.error?).to be(false)
    expect(inspector).to have_received(:table).with("app_prod", "users")
    expect(JSON.parse(response.content.first[:text], symbolize_names: true)).to eq(payload)
  end

  it "returns an error response when the table does not exist" do
    inspector = instance_double(MysqlDbBrowser::SchemaInspector)
    allow(inspector).to receive(:table).and_raise(MysqlDbBrowser::SchemaInspector::NotFound, "Table app_prod.missing was not found")
    allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(inspector)

    response = call(mysql_connection_id: connection.id, database: "app_prod", table: "missing")

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("was not found")
  end

  it "refuses when the connection has agentic access disabled" do
    disabled = Factories.mysql_connection(agentic_access_enabled: false)

    response = call(mysql_connection_id: disabled.id, database: "app_prod", table: "users")

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end
end
