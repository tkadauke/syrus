require "rails_helper"

# Read-only SQL is the common case of query execution, and the classifier
# already tells a SELECT from an UPDATE with certainty. Before the read
# classification was registered as its own capability there was nowhere to
# grant it: every query, plain SELECT included, was judged against the
# critical execute ceiling, so the longest authority an operator could give
# was a single invocation and routine reading meant approving each one.
RSpec.describe "permanent per-connection grant for read-only MySQL queries" do
  let(:user) { Factories.user }
  let(:connection) { Factories.mysql_connection(agentic_access_enabled: true) }
  let(:other_connection) { Factories.mysql_connection(agentic_access_enabled: true) }
  let(:execute_descriptor) do
    Permissions::Catalog.find!(capability: "mysql.query@v1", operation: "mysql.query/execute@v1")
  end

  before do
    PluginRecord.find_by!(name: "mysql_db_browser").update!(enabled: true)
    Syrus::PluginRegistry.clear_plugin_record_cache!
  end

  # The operator-facing path: draft a rule, preview it, apply it.
  def grant_permanent_read!(target)
    draft = Permissions::RuleDraft.new(user:, attributes: {
      "capability" => "mysql.query@v1", "operation" => "mysql.query/read@v1",
      "policy" => "allow", "duration" => "permanent",
      "subject_selector_type" => "interactive_chat",
      "resource_scope" => { "mysql_connection_id" => target.id }, "constraints" => {}
    })
    preview = draft.preview
    raise "draft invalid: #{preview.errors.inspect}" unless preview.valid?

    draft.apply!(digest: preview.digest, actor: user)
  end

  # Queries arrive at the tool's declared descriptor; the classifier decides
  # which operation the invocation actually is, and that is what a rule matches.
  # The context mirrors what AuthorizationRequest builds for a planner chat,
  # including the subject selector a rule is matched against.
  def authorize(sql, target)
    Permissions::Management.new(user).authorize(
      descriptor: execute_descriptor, role: AgentRole::CHAT_PLANNER,
      resource_scope: { "mysql_connection_id" => target.id },
      arguments: { sql:, mysql_connection_id: target.id },
      context: { role: AgentRole::CHAT_PLANNER, subject_selector_type: "interactive_chat" }
    )
  end

  it "can be granted permanently, which the critical execute ceiling forbids" do
    expect { grant_permanent_read!(connection) }.to change { PermissionRule.active.count }.by(1)

    expect(Permissions::Catalog.find!(capability: "mysql.query@v1", operation: "mysql.query/read@v1"))
      .to have_attributes(maximum_autonomy: :permanent, risk: :medium)
    expect(execute_descriptor).to have_attributes(maximum_autonomy: :invocation, risk: :critical)
  end

  it "authorizes a read without asking once the grant is in place" do
    grant_permanent_read!(connection)

    expect(authorize("SELECT id FROM orders LIMIT 10", connection)).to be_authorized
    expect(authorize("SHOW TABLES", connection)).to be_authorized
  end

  it "still asks for anything the classifier does not read as a read" do
    grant_permanent_read!(connection)

    # A different operation entirely, so the read grant cannot match it.
    expect(authorize("UPDATE orders SET total = 0", connection)).not_to be_authorized
    expect(authorize("DROP TABLE orders", connection)).not_to be_authorized
    expect(authorize("GRANT ALL ON *.* TO 'x'@'%'", connection)).not_to be_authorized
  end

  it "still asks for the forms the classifier refuses to call a read" do
    grant_permanent_read!(connection)

    # Multi-statement, executable comments, CTEs and EXPLAIN ANALYZE all fall
    # back to the ambiguous maximum rather than being read as SELECTs.
    [ "SELECT 1; DROP TABLE orders", "SELECT /*!40001 x */ 1",
      "WITH t AS (SELECT 1) SELECT * FROM t", "EXPLAIN ANALYZE SELECT 1" ].each do |sql|
      expect(authorize(sql, connection)).not_to be_authorized, "expected #{sql.inspect} to still ask"
    end
  end

  it "keeps the grant to the one connection it was scoped to" do
    grant_permanent_read!(connection)

    expect(authorize("SELECT 1", connection)).to be_authorized
    expect(authorize("SELECT 1", other_connection)).not_to be_authorized
  end

  it "never lets a read grant smuggle data out through a file write" do
    grant_permanent_read!(connection)

    expect(authorize("SELECT * FROM users INTO OUTFILE '/tmp/x'", connection)).not_to be_authorized
  end
end
