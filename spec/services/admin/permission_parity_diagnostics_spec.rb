require "rails_helper"

RSpec.describe Admin::PermissionParityDiagnostics do
  it "summarizes recent mismatch and safe-local failure diagnostics" do
    now = Time.current
    mismatch = instance_double(OperationalLogEvent, id: 1, occurred_at: now,
      context: { "status" => "mismatch", "capability" => "syrus.jobs@v1", "role" => "chat_planner",
        "tool_name" => "approve_job", "current_policy" => "allow", "shadow_policy" => "ask" })
    failure = instance_double(OperationalLogEvent, id: 2, occurred_at: now,
      context: { "status" => "evaluation_failed_safe_local", "capability" => "workspace.files@v1",
        "role" => "workflow_implement", "safe_local" => true })
    relation = double
    allow(relation).to receive(:where).with(source: Permissions::ShadowEvaluator::LOG_SOURCE).and_return(relation)
    allow(relation).to receive(:order).with(occurred_at: :desc).and_return(relation)
    allow(relation).to receive(:limit).with(100).and_return([ mismatch, failure ])

    payload = described_class.new(relation:).as_json

    expect(payload).to include(total: 2, mismatches: 1, evaluation_failures: 1, safe_local_failures: 1)
    expect(payload[:by_role]).to eq("chat_planner" => 1, "workflow_implement" => 1)
  end
end
