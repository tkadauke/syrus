require "rails_helper"

RSpec.describe MysqlQueryAudit do
  it "requires a statement, a connection, and a user" do
    audit = MysqlQueryAudit.new
    expect(audit).not_to be_valid
    expect(audit.errors[:statement]).to be_present

    audit.statement = "SELECT 1"
    expect(audit).not_to be_valid
    expect { audit.mysql_connection }.not_to raise_error
  end

  it "records a successful query attempt" do
    connection = Factories.mysql_connection
    user = Factories.user

    audit = MysqlQueryAudit.create!(
      mysql_connection: connection,
      user: user,
      statement: "SELECT * FROM users",
      read_only: true,
      success: true,
      row_count: 3,
      duration_ms: 12
    )

    expect(audit).to be_persisted
    expect(audit.success).to be true
    expect(audit.read_only).to be true
    expect(audit.row_count).to eq(3)
  end

  it "records a failed or rejected query attempt with an error message" do
    connection = Factories.mysql_connection
    user = Factories.user

    audit = MysqlQueryAudit.create!(
      mysql_connection: connection,
      user: user,
      statement: "DELETE FROM users",
      read_only: false,
      success: false,
      error_message: "Rejected: this connection is read-only."
    )

    expect(audit.success).to be false
    expect(audit.error_message).to include("read-only")
  end
end
