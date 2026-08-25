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
end
