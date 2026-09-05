require "rails_helper"

RSpec.describe PendingActions::CancelStaleWork do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_repository) { Factories.repository(user: admin) }

  def build_job(user:, repository:)
    Factories.job_record(state: "running", repository: repository, user: user)
  end

  def active_workflow_for(job)
    workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", state: "running")
    attach_work_unit(workflow, state: "running")
    workflow
  end

  def active_run_for(job, state: "queued")
    Run.create!(job: job, user: job.user, trigger_kind: "initial", agent_provider: "claude", state: state)
  end

  def pending_action_for(user, repository, reason: "operator cleanup", **payload)
    chat_session = ChatSession.create!(user: user, repository: repository)
    chat_session.pending_actions.create!(
      action: "cancel_stale_work",
      requested_by: "agent",
      reason: reason,
      payload: payload
    )
  end

  it "requires the acting user to be an admin" do
    Factories.user(admin: true) # the DB's first-ever user is auto-promoted to admin; seed one so `member` below isn't it
    member = Factories.user
    member_repository = Factories.repository(user: member)
    job = build_job(user: member, repository: member_repository)
    active_workflow_for(job)
    action = pending_action_for(member, member_repository, "job_id" => job.id)

    expect { action.confirm!(user: member) }.to raise_error(ArgumentError, /Admin access required/)
  end

  it "requires job_id and a reason" do
    expect { pending_action_for(admin, admin_repository, reason: "", "job_id" => nil) }
      .to raise_error(ActiveRecord::RecordInvalid, /job_id is required/)
  end

  it "cancels active workflows and queued runs, then reconciles the Job through the concurrency-guarded entry point" do
    job = build_job(user: admin, repository: admin_repository)
    workflow = active_workflow_for(job)
    run = active_run_for(job)
    action = pending_action_for(admin, admin_repository, "job_id" => job.id)

    expect(WorkEngine::Reconciler).to receive(:call_locked!)
      .with(source: "operator:cancel_stale_work", job_id: job.id, execute_repairs: true)
      .and_return(nil)

    action.confirm!(user: admin)

    expect(action.reload).to be_confirmed
    expect(workflow.reload).to be_cancelled
    expect(run.reload).to be_cancelled
  end

  it "does not reconcile when the payload opts out" do
    job = build_job(user: admin, repository: admin_repository)
    active_workflow_for(job)
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "reconcile" => false)

    expect(WorkEngine::Reconciler).not_to receive(:call_locked!)

    action.confirm!(user: admin)

    expect(action.reload).to be_confirmed
  end

  it "audits the cancellation on the Job's most recent Run, not merely the first one found" do
    job = build_job(user: admin, repository: admin_repository)
    active_workflow_for(job)
    older_run = active_run_for(job, state: "failed")
    older_run.update_columns(created_at: 10.minutes.ago)
    audit_run = active_run_for(job, state: "failed")
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "reconcile" => false)

    action.confirm!(user: admin)

    expect(JobLog.where(run: audit_run).pluck(:chunk)).to include(match(/cancelled stale work/))
    expect(JobLog.where(run: older_run)).to be_empty
  end

  it "only cancels the explicitly requested workflow ids" do
    job = build_job(user: admin, repository: admin_repository)
    keep = active_workflow_for(job)
    other_workflow = Workflow.create!(job: job, trigger_kind: "retry", agent_provider: "claude", state: "running")
    attach_work_unit(other_workflow, state: "running", kind: "retry")
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "workflow_ids" => [ other_workflow.id ], "reconcile" => false)

    action.confirm!(user: admin)

    expect(other_workflow.reload).to be_cancelled
    expect(keep.reload).to be_running
  end

  it "only cancels the explicitly requested run ids" do
    job = build_job(user: admin, repository: admin_repository)
    keep = active_run_for(job)
    other_run = active_run_for(job)
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "run_ids" => [ other_run.id ], "reconcile" => false)

    action.confirm!(user: admin)

    expect(other_run.reload).to be_cancelled
    expect(keep.reload).to be_queued
  end

  it "raises when a requested workflow id is not active work for the Job" do
    job = build_job(user: admin, repository: admin_repository)
    active_workflow_for(job)
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "workflow_ids" => [ 999_999 ])

    expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /Workflow ids are not active work/)
  end

  it "raises when a requested run id is not active work for the Job" do
    job = build_job(user: admin, repository: admin_repository)
    active_workflow_for(job)
    action = pending_action_for(admin, admin_repository, "job_id" => job.id, "run_ids" => [ 999_999 ])

    expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /Run ids are not active work/)
  end
end
