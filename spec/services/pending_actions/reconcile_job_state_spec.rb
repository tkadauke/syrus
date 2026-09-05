require "rails_helper"

RSpec.describe PendingActions::ReconcileJobState do
  let(:admin) { Factories.user(admin: true) }
  let(:admin_repository) { Factories.repository(user: admin) }

  def build_job(state, **attrs)
    Factories.job_record(state: state, repository: admin_repository, user: admin, **attrs)
  end

  def terminal_workflow_for(job, state: "succeeded")
    workflow = Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude")
    workflow.update_columns(state: state, finished_at: Time.current)
    workflow
  end

  def pending_action_for(user, repository, reason: "operator repair", **payload)
    chat_session = ChatSession.create!(user: user, repository: repository)
    chat_session.pending_actions.create!(
      action: "reconcile_job_state",
      requested_by: "agent",
      reason: reason,
      payload: payload
    )
  end

  it "requires the acting user to be an admin" do
    Factories.user(admin: true) # the DB's first-ever user is auto-promoted to admin; seed one so `member` below isn't it
    member = Factories.user
    member_repository = Factories.repository(user: member)
    job = Factories.job_record(state: "failed", repository: member_repository, user: member)
    action = pending_action_for(member, member_repository, "job_id" => job.id, "mode" => "auto")

    expect { action.confirm!(user: member) }.to raise_error(ArgumentError, /Admin access required/)
  end

  it "rejects an invalid mode at validation time" do
    job = build_job("failed")

    expect { pending_action_for(admin, admin_repository, "job_id" => job.id, "mode" => "bogus") }
      .to raise_error(ActiveRecord::RecordInvalid, /mode is invalid/)
  end

  it "requires job_id and a reason" do
    expect { pending_action_for(admin, admin_repository, reason: "", "job_id" => nil, "mode" => "auto") }
      .to raise_error(ActiveRecord::RecordInvalid, /job_id is required/)
  end

  describe "auto mode" do
    it "runs the real, unstubbed WorkEngine reconciler and applies a repair end to end" do
      job = Factories.job(user: admin, repository: admin_repository, agent_provider: "claude")
      run = job.initial_run
      workflow = run.workflow
      step = run.step
      workflow.update_columns(state: "running", started_at: 5.minutes.ago)
      step.update_columns(state: "running", started_at: 5.minutes.ago)
      run.update_columns(state: "running", started_at: 5.minutes.ago, last_heartbeat_at: 1.minute.ago)
      job.update_columns(state: "closed", finished_at: 2.minutes.ago, closure_reason: "operator_cancelled")
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "mode" => "auto")

      expect(action.confirm!(user: admin)).to be true

      expect(workflow.reload).to be_cancelled
      expect(run.reload).to be_cancelled
      expect(action.reload).to be_confirmed
      expect(action.result).to eq(job.reload)
    end
  end

  describe "mark_implemented_from_ready_pr mode" do
    it "transitions the Job through the real, unstubbed JobStateRepair" do
      job = build_job("running", pr_number: 1)
      terminal_workflow_for(job)
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "mode" => "mark_implemented_from_ready_pr")

      expect(action.confirm!(user: admin)).to be true

      expect(job.reload.state).to eq("implemented")
      expect(action.reload.result).to eq(job)
    end

    it "surfaces the underlying ArgumentError when the Job has no PR recorded" do
      job = build_job("running")
      terminal_workflow_for(job)
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "mode" => "mark_implemented_from_ready_pr")

      expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /no PR recorded/)
    end
  end

  describe "mark_failed mode" do
    it "transitions the Job through the real, unstubbed JobStateRepair" do
      job = build_job("running")
      terminal_workflow_for(job)
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "mode" => "mark_failed")

      expect(action.confirm!(user: admin)).to be true

      expect(job.reload.state).to eq("failed")
    end
  end

  describe "mark_queued mode" do
    it "transitions the Job through the real, unstubbed JobStateRepair" do
      job = build_job("failed")
      terminal_workflow_for(job, state: "failed")
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "mode" => "mark_queued")

      expect(action.confirm!(user: admin)).to be true

      expect(job.reload.state).to eq("queued")
    end
  end
end
