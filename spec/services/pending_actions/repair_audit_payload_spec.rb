require "rails_helper"

RSpec.describe PendingActions::RepairAuditPayload do
  it "references large snapshots without copying them into AdminAction TEXT params" do
    action = instance_double(
      ChatPendingAction,
      id: 9, pending_action_group_id: 3, chat_session_id: 4, repository_id: 5,
      action: "repair_queue_affinity", action_type: nil, reason: "repair",
      requested_by: "agent", payload: { "run_id" => 7 },
      before_snapshot: { "captured_at" => "before", "jobs" => [ { "id" => 1, "artifact" => "x" * 45_000 } ] },
      after_snapshot: { "captured_at" => "after", "jobs" => [ { "id" => 1, "artifact" => "y" * 45_000 } ] }
    )

    payload = described_class.build(pending_action: action, record: nil)

    expect(JSON.generate(payload).bytesize).to be <= described_class::MAX_BYTES
    expect(payload).not_to include(:before_snapshot, :after_snapshot)
    expect(payload.dig(:evidence, :before)).to include(job_ids: [ 1 ], bytes: be > 40_000, sha256: match(/\A[0-9a-f]{64}\z/))
    expect(payload[:outcome]).to eq("applied")
  end
end
