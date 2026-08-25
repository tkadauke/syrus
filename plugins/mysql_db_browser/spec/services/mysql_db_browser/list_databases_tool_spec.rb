require "rails_helper"

RSpec.describe MysqlDbBrowser::ListDatabasesTool do
  let(:connection) { Factories.mysql_connection(agentic_access_enabled: true) }

  def call(mysql_connection_id:)
    described_class.call(server_context: {}, mysql_connection_id: mysql_connection_id)
  end

  it "returns the connection's databases payload" do
    payload = { available: true, databases: [ { name: "app_prod", system_schema: false } ] }
    allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(instance_double(MysqlDbBrowser::SchemaInspector, databases: payload))

    response = call(mysql_connection_id: connection.id)

    expect(response.error?).to be(false)
    expect(JSON.parse(response.content.first[:text], symbolize_names: true)).to eq(payload)
  end

  it "refuses when the connection has agentic access disabled" do
    disabled = Factories.mysql_connection(agentic_access_enabled: false)

    response = call(mysql_connection_id: disabled.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Agentic access is disabled")
  end

  it "refuses for an unknown connection id" do
    response = call(mysql_connection_id: -1)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("was not found")
  end

  it "surfaces a connection failure as an error response" do
    allow(MysqlDbBrowser::SchemaInspector).to receive(:new).with(connection).and_return(
      instance_double(MysqlDbBrowser::SchemaInspector).tap { |inspector| allow(inspector).to receive(:databases).and_raise(MysqlDbBrowser::SchemaInspector::Unavailable, "Access denied") }
    )

    response = call(mysql_connection_id: connection.id)

    expect(response.error?).to be(true)
    expect(response.content.first[:text]).to include("Access denied")
  end
end
