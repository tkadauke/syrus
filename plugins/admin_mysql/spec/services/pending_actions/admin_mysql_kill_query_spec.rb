require "rails_helper"

RSpec.describe PendingActions::AdminMysqlKillQuery do
  it "kills the captured statement only after an admin confirms" do
    admin = Factories.user(admin: true)
    chat_session = ChatSession.create!(user: admin)
    pending_action = chat_session.pending_actions.create!(
      action: "admin_mysql_kill_query",
      payload: { "thread_id" => 42, "statement" => "SELECT * FROM jobs", "statement_verifier" => "safe-verifier" },
      requested_by: "agent"
    )
    inspector = instance_double(AdminMysql::Inspector)
    allow(AdminMysql::Inspector).to receive(:new).and_return(inspector)
    allow(inspector).to receive(:kill_query).and_return(killed: true, thread_id: 42)

    expect(pending_action.confirm!(user: admin)).to be(true)
    expect(inspector).to have_received(:kill_query).with(
      42,
      expected_statement: "SELECT * FROM jobs",
      expected_statement_verifier: "safe-verifier"
    )
    expect(pending_action.reload).to be_confirmed
  end

  it "records a failed confirmation when the statement changed" do
    admin = Factories.user(admin: true)
    chat_session = ChatSession.create!(user: admin)
    pending_action = chat_session.pending_actions.create!(
      action: "admin_mysql_kill_query",
      payload: { "thread_id" => 42, "statement" => "SELECT * FROM jobs" },
      requested_by: "agent"
    )
    inspector = instance_double(AdminMysql::Inspector)
    allow(AdminMysql::Inspector).to receive(:new).and_return(inspector)
    allow(inspector).to receive(:kill_query).and_raise(ArgumentError, "MySQL thread 42 is now running a different statement")

    expect { pending_action.confirm!(user: admin) }.to raise_error(ArgumentError, /different statement/)
    expect(pending_action.reload).to be_failed
    expect(pending_action.execution_error).to include("different statement")
  end

  it "re-checks admin access at confirmation time" do
    admin = Factories.user(admin: true)
    chat_session = ChatSession.create!(user: admin)
    pending_action = chat_session.pending_actions.create!(
      action: "admin_mysql_kill_query",
      payload: { "thread_id" => 42, "statement" => "SELECT * FROM jobs" },
      requested_by: "agent"
    )
    admin.update!(global_role: "user")

    expect { pending_action.confirm!(user: admin) }.to raise_error(ArgumentError, /Admin access required/)
    expect(pending_action.reload).to be_failed
  end
end
