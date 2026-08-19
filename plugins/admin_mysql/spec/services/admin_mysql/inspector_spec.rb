require "rails_helper"

RSpec.describe AdminMysql::Inspector do
  it "reports unavailable when the Rails adapter is not mysql2" do
    expect(described_class.mysql?).to be(false)

    expect {
      described_class.new.snapshot
    }.to raise_error(described_class::Unavailable, /mysql2 adapter/)
  end

  it "normalizes missing Performance Schema permissions into actionable hints" do
    payload = described_class.new.send(
      :error_payload,
      StandardError.new("Mysql2::Error: SELECT command denied to user 'syrus' for table 'events_statements_summary_by_digest'")
    )

    expect(payload).to include(
      message: "The Syrus MySQL user cannot read Performance Schema statement digests.",
      hint: include("Grant SELECT")
    )
    expect(payload.fetch(:setup_sql)).to include(include("performance_schema.events_statements_summary_by_digest"))
  end

  it "normalizes missing slow-log table permissions into actionable hints" do
    payload = described_class.new.send(
      :error_payload,
      StandardError.new("Mysql2::Error: SELECT command denied to user 'syrus' for table 'slow_log'")
    )

    expect(payload).to include(
      message: "The Syrus MySQL user cannot read mysql.slow_log.",
      hint: include("Grant SELECT")
    )
    expect(payload.fetch(:setup_sql)).to include(include("mysql.slow_log"))
  end
end
