require "rails_helper"

RSpec.describe MysqlConnection do
  it "requires label, host, and username" do
    connection = MysqlConnection.new

    expect(connection).not_to be_valid
    expect(connection.errors[:label]).to be_present
    expect(connection.errors[:host]).to be_present
    expect(connection.errors[:username]).to be_present
  end

  it "requires a port between 1 and 65535" do
    connection = MysqlConnection.new(label: "t", host: "h", username: "u", port: 0)
    expect(connection).not_to be_valid
    expect(connection.errors[:port]).to be_present

    connection.port = 70_000
    expect(connection).not_to be_valid
    expect(connection.errors[:port]).to be_present

    connection.port = 3306
    connection.valid?
    expect(connection.errors[:port]).to be_empty
  end

  it "defaults agentic_access_enabled to false" do
    connection = Factories.mysql_connection
    expect(connection.agentic_access_enabled).to be false
  end

  describe "credential encryption" do
    it "round-trips the password through the encrypted credentials column" do
      connection = Factories.mysql_connection
      connection.password = "s3cret"
      connection.save!

      reloaded = MysqlConnection.find(connection.id)
      expect(reloaded.password).to eq("s3cret")
    end

    it "never stores the plaintext password in the raw database column" do
      connection = Factories.mysql_connection(password: "s3cret")

      raw_value = ActiveRecord::Base.connection.select_value(
        "SELECT credentials FROM mysql_connections WHERE id = #{connection.id}"
      )

      expect(raw_value.to_s).not_to include("s3cret")
    end

    it "defaults credentials to an empty hash" do
      connection = MysqlConnection.new
      expect(connection.credentials).to eq({})
      expect(connection.password).to be_nil
    end
  end
end
