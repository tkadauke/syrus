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

  it "raises when the event cannot be applied from the Job's current state" do
    job = build_job("queued")
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "event" => "approve")

    expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /cannot apply approve from queued/)
  end

  it "applies close from failed to closed" do
    job = build_job("failed")
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "event" => "close")

    expect(action.confirm!(user: admin)).to be true

    expect(job.reload.state).to eq("closed")
  end
end
