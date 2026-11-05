require "rails_helper"

RSpec.describe Admin::PermissionParityDiagnostics do
  it "summarizes effective policy by actor and invocation" do
    now = Time.current
    allowed = instance_double(OperationalLogEvent, id: 1, occurred_at: now,
      context: { "capability" => "syrus.jobs@v1", "role" => "chat_planner",
        "policy" => "allow", "effective_policy" => "allow", "actor_type" => "User",
        "actor_id" => 7, "invocation_fingerprint" => "abc" })
    asked = instance_double(OperationalLogEvent, id: 2, occurred_at: now,
      context: { "capability" => "workspace.files@v1", "role" => "workflow_implement",
        "policy" => "ask", "effective_policy" => "ask", "actor_type" => "Coworkers::Coworker",
        "actor_id" => 8, "invocation_fingerprint" => "def" })
    relation = double
    allow(relation).to receive(:where).with(source: Permissions::DecisionAudit::LOG_SOURCE).and_return(relation)
    allow(relation).to receive(:order).with(occurred_at: :desc).and_return(relation)
    allow(relation).to receive(:limit).with(100).and_return([ allowed, asked ])

    payload = described_class.new(relation:).as_json

    expect(payload).to include(total: 2, policies: { "allow" => 1, "ask" => 1 })
    expect(payload[:by_role]).to eq("chat_planner" => 1, "workflow_implement" => 1)
    expect(payload[:by_actor]).to eq("Coworkers::Coworker:8" => 1, "User:7" => 1)
    expect(payload[:by_invocation]).to eq("abc" => 1, "def" => 1)
  end
end
