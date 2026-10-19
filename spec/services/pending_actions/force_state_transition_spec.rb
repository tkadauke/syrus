require "rails_helper"

RSpec.describe PendingActions::ForceStateTransition do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_repository) { Factories.repository(user: admin) }

  def build_job(state, **attrs)
    Factories.job_record(state: state, repository: admin_repository, user: admin, **attrs)
  end

  def pending_action_for(user, repository, reason: "operator repair", **payload)
    chat_session = ChatSession.create!(user: user, repository: repository)
    chat_session.pending_actions.create!(
      action: "force_state_transition",
      requested_by: "agent",
      reason: reason,
      payload: payload
    )
  end

  it "requires the acting user to be an admin" do
    Factories.user(admin: true) # the DB's first-ever user is auto-promoted to admin; seed one so `member` below isn't it
    member = Factories.user
    member_repository = Factories.repository(user: member)
    job = Factories.job_record(state: "implemented", repository: member_repository, user: member)
    action = pending_action_for(member, member_repository, "job_id" => job.id, "event" => "force_fail")

    expect { action.confirm!(user: member) }.to raise_error(ArgumentError, /Admin access required/)
  end

  it "rejects events outside the allowlist at validation time" do
    job = build_job("queued")

    expect { pending_action_for(admin, admin_repository, "job_id" => job.id, "event" => "create_initial_run") }
      .to raise_error(ActiveRecord::RecordInvalid, /event is invalid/)
  end

  it "requires job_id and a reason" do
    expect { pending_action_for(admin, admin_repository, reason: "", "job_id" => nil, "event" => "force_fail") }
      .to raise_error(ActiveRecord::RecordInvalid, /job_id is required/)
  end

  it "applies the forced transition through the real, unstubbed JobStateRepair and records an audit trail" do
    job = build_job("implemented")
    run = Run.create!(job: job, user: job.user, trigger_kind: "initial", agent_provider: "claude", state: "failed", finished_at: 1.minute.ago)
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "event" => "force_fail")

    expect(action.confirm!(user: admin)).to be true

    expect(job.reload.state).to eq("failed")
    expect(action.reload).to be_confirmed
    expect(action.result).to eq(job)
    expect(JobLog.where(run: run).pluck(:chunk)).to include(a_string_matching(/forced Job event force_fail: implemented -> failed/))
    expect(action.before_snapshot).to include("jobs")
    expect(action.after_snapshot).to include("jobs")
  end

  it "audits against the most recently created Run, not merely the first one found" do
    job = build_job("implemented")
    older = Run.create!(job: job, user: job.user, trigger_kind: "initial", agent_provider: "claude", state: "succeeded")
    older.update_columns(created_at: 10.minutes.ago)
    newer = Run.create!(job: job, user: job.user, trigger_kind: "initial", agent_provider: "claude", state: "failed", finished_at: 1.minute.ago)
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "event" => "force_fail")

    expect(action.confirm!(user: admin)).to be true

    expect(JobLog.where(run: newer).pluck(:chunk)).to include(a_string_matching(/forced Job event force_fail: implemented -> failed/))
    expect(JobLog.where(run: older)).to be_empty
  end

  it "rejects an event that cannot be applied from the Job's current state at validation time" do
    job = build_job("queued")

    expect { pending_action_for(admin, admin_repository, "job_id" => job.id, "event" => "approve") }
      .to raise_error(ActiveRecord::RecordInvalid, /cannot apply approve from queued/)
  end

  it "applies close from failed to closed" do
    job = build_job("failed")
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "event" => "close")

    expect(action.confirm!(user: admin)).to be true

    expect(job.reload.state).to eq("closed")
  end

  it "retires active runtime ownership before forcing a terminal Job state" do
    job = build_job("running")
    workflow = WorkUnits::Launcher.instantiate(
      kind: "coding_handoff",
      job: job,
      idempotency_key: "forced-terminal-state"
    )
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "event" => "mark_failed")

    expect(action.confirm!(user: admin)).to be true

    expect(job.reload).to be_failed
    expect(workflow.reload).to be_cancelled
    expect(workflow.work_unit.reload).to be_cancelled
    expect(workflow.work_unit.work_intent.reload).to be_cancelled
    expect(workflow.work_unit.work_unit_locks.active).to be_empty
    expect(action.after_snapshot.dig("jobs", 0, "runtime_ownership", "work_units", 0)).to include(
      "id" => workflow.work_unit.id,
      "state" => "cancelled",
      "work_intent_state" => "cancelled",
      "active_lock_ids" => []
    )
  end

  it "leaves a forced implemented Job available for Coding Mode after cancelling a zero-run handoff" do
    allow(Feature).to receive(:coding_mode_enabled?).and_return(true)
    allow(ChatWorkspace).to receive(:ensure_job_branch_checkout!)
    admin.update!(github_token: "test-token")
    job = build_job("running", branch_name: "syrus/direct-reopen-in-coding")
    workflow = WorkUnits::Launcher.instantiate(
      kind: "coding_handoff",
      job: job,
      idempotency_key: "forced-implemented-state"
    )
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "event" => "mark_implemented")

    action.confirm!(user: admin)

    coding_chat = ChatSession.create!(user: admin, repository: admin_repository, mode: "coding")
    result = JobCodingMode::Takeover.call(job: job.reload, user: admin, chat_session: coding_chat)

    expect(workflow.reload).to be_cancelled
    expect(result.job).to be_coding
    expect(result.job.linked_chat_id).to eq(coding_chat.id)
  end
end
