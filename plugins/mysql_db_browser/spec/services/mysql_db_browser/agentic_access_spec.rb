require "rails_helper"

RSpec.describe MysqlDbBrowser::AgenticAccess do
  describe ".connection!" do
    it "returns the connection when agentic access is enabled" do
      connection = Factories.mysql_connection(agentic_access_enabled: true)

      expect(described_class.connection!(connection.id)).to eq(connection)
    end

    it "raises AccessDisabled when the connection has not opted in" do
      connection = Factories.mysql_connection(agentic_access_enabled: false)

      expect { described_class.connection!(connection.id) }.to raise_error(described_class::AccessDisabled, /Agentic access is disabled/)
    end

    it "raises ConnectionNotFound for an unknown id" do
      expect { described_class.connection!(-1) }.to raise_error(described_class::ConnectionNotFound)
    end
  end

  describe ".connection_with_write_access!" do
    it "returns the connection when it has opted into writes" do
      connection = Factories.mysql_connection(allow_writes: true)

      expect(described_class.connection_with_write_access!(connection)).to eq(connection)
    end

    it "raises WriteAccessDisabled when the connection has not opted into writes" do
      connection = Factories.mysql_connection(allow_writes: false)

      expect {
        described_class.connection_with_write_access!(connection)
      }.to raise_error(described_class::WriteAccessDisabled, /Write access is disabled/)
    end

    it "does not re-check agentic_access_enabled, since the caller already resolved the connection" do
      connection = Factories.mysql_connection(agentic_access_enabled: false, allow_writes: true)

      expect(described_class.connection_with_write_access!(connection)).to eq(connection)
    end
  end
end
