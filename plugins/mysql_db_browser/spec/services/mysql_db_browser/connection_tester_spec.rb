require "rails_helper"

RSpec.describe MysqlDbBrowser::ConnectionTester do
  it "reports success when the query succeeds" do
    fake_client = instance_double(Mysql2::Client, query: [], close: nil)
    original = described_class.client_factory
    described_class.client_factory = ->(**) { fake_client }

    result = described_class.test_params(host: "h", port: 3306, username: "u", password: "p", database: "d")

    expect(result).to eq(success: true)
    expect(fake_client).to have_received(:query).with("SELECT 1")
    expect(fake_client).to have_received(:close)
  ensure
    described_class.client_factory = original
  end

  it "reports failure with the driver's error message and does not raise" do
    original = described_class.client_factory
    described_class.client_factory = ->(**) { raise Mysql2::Error, "Access denied for user 'u'@'h'" }

    result = described_class.test_params(host: "h", port: 3306, username: "u", password: "wrong")

    expect(result).to eq(success: false, error: "Access denied for user 'u'@'h'")
  ensure
    described_class.client_factory = original
  end

  it "closes the client even when the query itself raises" do
    fake_client = instance_double(Mysql2::Client, close: nil)
    allow(fake_client).to receive(:query).and_raise(Mysql2::Error, "Unknown database 'd'")
    original = described_class.client_factory
    described_class.client_factory = ->(**) { fake_client }

    result = described_class.test_params(host: "h", port: 3306, username: "u", password: "p", database: "d")

    expect(result).to eq(success: false, error: "Unknown database 'd'")
    expect(fake_client).to have_received(:close)
  ensure
    described_class.client_factory = original
  end

  it "builds the client from a persisted connection's decrypted credentials" do
    connection = Factories.mysql_connection(host: "db.internal", port: 3307, username: "app", password: "s3cret", default_database: "app_prod")
    fake_client = instance_double(Mysql2::Client, query: [], close: nil)
    received_options = nil
    original = described_class.client_factory
    described_class.client_factory = lambda { |**opts|
      received_options = opts
      fake_client
    }

    described_class.test(connection)

    expect(received_options).to include(host: "db.internal", port: 3307, username: "app", password: "s3cret", database: "app_prod")
  ensure
    described_class.client_factory = original
  end
end
