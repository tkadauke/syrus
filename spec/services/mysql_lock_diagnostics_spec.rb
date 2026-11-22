require "rails_helper"

RSpec.describe MysqlLockDiagnostics do
  it "reports nothing on a database without InnoDB lock tables" do
    expect(described_class.snapshot).to eq([])
  end

  it "reads long-open transactions with their thread, age and statement on MySQL" do
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, adapter_name: "Mysql2")
    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
    allow(connection).to receive(:select_all).and_return(
      ActiveRecord::Result.new(
        %w[trx_id trx_mysql_thread_id trx_age_seconds trx_rows_locked trx_query processlist_info processlist_time],
        [ [ "4711", 88, 172, 3, nil, "UPDATE jobs SET state = 'landing' WHERE id = 9", 172 ] ]
      )
    )

    expect(described_class.snapshot).to eq([
      {
        "trx_id" => "4711", "thread_id" => 88, "age_seconds" => 172, "rows_locked" => 3,
        "statement" => "UPDATE jobs SET state = 'landing' WHERE id = 9"
      }
    ])
  end

  it "never raises out of a diagnostic query" do
    connection = instance_double(ActiveRecord::ConnectionAdapters::AbstractAdapter, adapter_name: "Mysql2")
    allow(ActiveRecord::Base).to receive(:connection).and_return(connection)
    allow(connection).to receive(:select_all).and_raise(ActiveRecord::StatementInvalid, "access denied")

    expect(described_class.snapshot).to eq([])
  end
end
