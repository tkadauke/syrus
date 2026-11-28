require "rails_helper"

RSpec.describe MaintenanceTasks::Definitions::JobClosureReasonBackfill do
  let(:definition) { described_class.new }
  let(:task) { MaintenanceTask.new(checkpoint: {}) }

  it "maps legacy reasons in an idempotent primary-key batch" do
    no_change = Factories.job(state: "closed", closure_reason: "no_changes")
    approved = Factories.job(state: "closed", closure_reason: "pr_approved", landed_sha: "abc123")
    recorded_merge = Factories.job(state: "closed", closure_reason: "pr_approved")
    JobPrLink.create!(job: recorded_merge, role: JobPrLink::ROLE_LOCAL, metadata: { "pr_state" => "merged" })
    closed_pr = Factories.job(state: "closed", closure_reason: "pr_approved")
    grader = Factories.job(state: "closed", closure_reason: nil, kind: "main_grader", issue_number: nil)

    result = definition.perform_batch(task)

    expect(result.processed).to be >= 2
    expect(no_change.reload.closure_reason).to eq("not_needed")
    expect(approved.reload.closure_reason).to eq("pr_merged")
    expect(recorded_merge.reload.closure_reason).to eq("pr_merged")
    expect(closed_pr.reload.closure_reason).to eq("pr_closed")
    expect(grader.reload.closure_reason).to eq("main_grader")
    expect(definition.perform_batch(task).processed).to eq(0)
  end

  it "retains an ambiguous human cancellation" do
    cancelled = Factories.job(state: "closed", closure_reason: "cancelled")

    definition.perform_batch(task)

    expect(cancelled.reload.closure_reason).to eq("cancelled")
  end


  it "maps cancellation evidence in one batch and preserves recorded provenance" do
    canonical = Factories.job(state: "implemented")
    duplicate = Factories.job(state: "closed", closure_reason: "cancelled", issue_number: 43)
    from_transition = Factories.job(state: "closed", closure_reason: "cancelled", issue_number: 44)
    from_action = Factories.job(state: "closed", closure_reason: "cancelled", issue_number: 45)
    ChatPendingAction.create!(
      user: duplicate.user, action: "cancel_job", state: "confirmed", requested_by: "agent",
      payload: { "job_id" => duplicate.id, "canonical_job_id" => canonical.id }
    )
    ChatPendingAction.create!(
      user: from_action.user, action: "cancel_job", state: "confirmed", requested_by: "agent",
      payload: { "job_id" => from_action.id, "reason" => "obsolete" }
    )
    StateTransition.create!(
      subject: from_transition, from_state: "implemented", to_state: "closed", event_name: "close",
      source: "tool", user: from_transition.user,
      metadata: {
        "reason_key" => "infeasible", "note" => "The upstream API cannot represent this operation.",
        "actor_type" => "agent", "chat_session_id" => 17
      }
    )
    expect(ChatPendingAction).to receive(:where).with(action: "cancel_job").once.and_call_original

    definition.perform_batch(task)

    expect(duplicate.reload).to have_attributes(
      closure_reason: "duplicate", closure_references: [ { "type" => "Job", "id" => canonical.id } ]
    )
    expect(from_action.reload.closure_reason).to eq("obsolete")
    expect(from_transition.reload).to have_attributes(
      closure_reason: "infeasible", closure_note: "The upstream API cannot represent this operation."
    )
    audit = StateTransition.where(subject: from_transition, event_name: "closure_reason_backfill").sole
    expect(audit).to have_attributes(source: "backfill", user: from_transition.user)
    expect(audit.metadata).to include("actor_type" => "agent", "chat_session_id" => 17, "via" => "tool")
  end
end
