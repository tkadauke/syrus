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

  # A holder is only guaranteed to be as old as the waiter's timeout. A
  # threshold above it missed the holder of a production lock-wait timeout
  # whose request took 13s end to end.
  it "looks for holders younger than the configured lock wait timeout" do
    configured = YAML.safe_load(
      ERB.new(Rails.root.join("config/database.yml").read).result, aliases: true
    ).dig("production", "primary", "variables", "innodb_lock_wait_timeout")

    expect(configured).to be_a(Integer)
    expect(described_class::LONG_OPEN_TRANSACTION_SECONDS).to be < configured
    expect(described_class::QUERY).to include("INTERVAL #{described_class::LONG_OPEN_TRANSACTION_SECONDS} SECOND")
  end
end
