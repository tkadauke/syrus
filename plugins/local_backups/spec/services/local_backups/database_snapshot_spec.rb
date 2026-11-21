require "rails_helper"

RSpec.describe LocalBackups::DatabaseSnapshot do
  it "selects snapshot drivers by adapter family" do
    sqlite = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, adapter_name: "SQLite")
    mysql = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, adapter_name: "Mysql2")

    expect(described_class.for(connection: sqlite)).to be_a(LocalBackups::SqliteSnapshot)
    expect(described_class.for(connection: mysql, config: {})).to be_a(LocalBackups::MysqlSnapshot)
  end

  it "fails closed for unsupported database adapters" do
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, adapter_name: "PostgreSQL")

    expect { described_class.for(connection:) }
      .to raise_error(LocalBackups::Creator::UnsupportedDatabase, /PostgreSQL/)
  end
end
