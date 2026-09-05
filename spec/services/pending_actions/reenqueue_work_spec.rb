require "rails_helper"

RSpec.describe PendingActions::ReenqueueWork do
  include ActiveJob::TestHelper

  let(:admin) { Factories.user(admin: true) }
  let(:admin_repository) { Factories.repository(user: admin) }

  def build_job(state: "running", **attrs)
    Factories.job_record(state: state, repository: admin_repository, user: admin, agent_provider: "claude", **attrs)
  end

  def build_workflow(job, workflow_state: "running", unit_state: workflow_state)
    workflow = Workflows::Initial.instantiate(job: job, agent_provider: "claude")
    workflow.update_columns(state: workflow_state)
    attach_work_unit(workflow, state: unit_state)
    workflow
  end

  def build_run(job, workflow, state: "queued")
    Run.create!(
      job: job,
      user: job.user,
      step: workflow.first_step,
      trigger_kind: "initial",
      agent_provider: "claude",
      state: state
    )
  end

  def pending_action_for(user, repository, reason: "re-enqueue queued work", **payload)
    chat_session = ChatSession.create!(user: user, repository: repository)
    chat_session.pending_actions.create!(
      action: "reenqueue_work",
      requested_by: "agent",
      reason: reason,
      payload: payload
    )
  end

  it "requires the acting user to be an admin" do
    Factories.user(admin: true) # the DB's first-ever user is auto-promoted to admin; seed one so `member` below isn't it
    member = Factories.user
    member_repository = Factories.repository(user: member)
    job = Factories.job_record(state: "running", repository: member_repository, user: member)
    action = pending_action_for(member, member_repository, "job_id" => job.id)

    expect { action.confirm!(user: member) }.to raise_error(ArgumentError, /Admin access required/)
  end

  it "requires job_id and a reason" do
    expect { pending_action_for(admin, admin_repository, reason: "", "job_id" => nil) }
      .to raise_error(ActiveRecord::RecordInvalid, /job_id is required/)
  end

  describe "explicit run_id" do
    it "re-enqueues the specified queued Run and audits it" do
      job = build_job
      workflow = build_workflow(job)
      run = build_run(job, workflow, state: "queued")
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "run_id" => run.id)

      expect {
        expect(action.confirm!(user: admin)).to be true
      }.to have_enqueued_job(RunJob).with(run.id)

      expect(action.reload).to be_confirmed
      expect(action.result).to eq(run)
      expect(JobLog.where(run: run).pluck(:chunk)).to include(a_string_matching(/re-enqueued work via #{Regexp.escape(run.slug)}/))
    end

    it "raises when the specified Run is not found" do
      job = build_job
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "run_id" => 999_999)

      expect { action.confirm!(user: admin) }.to raise_error(ActiveRecord::RecordNotFound)
    end

    it "raises when the specified Run is not queued" do
      job = build_job
      workflow = build_workflow(job)
      run = build_run(job, workflow, state: "running")
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "run_id" => run.id)

      expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /not queued/)
    end

    it "raises when the Run's Workflow is not active" do
      job = build_job
      workflow = build_workflow(job, workflow_state: "succeeded", unit_state: "succeeded")
      run = build_run(job, workflow, state: "queued")
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "run_id" => run.id)

      expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /Workflow is not active/)
    end
  end

  describe "no explicit ids" do
    it "falls back to the most recently created queued Run for the Job" do
      job = build_job
      workflow = build_workflow(job)
      older = build_run(job, workflow, state: "queued")
      older.update_columns(created_at: 5.minutes.ago)
      newer = build_run(job, workflow, state: "queued")
      action = pending_action_for(admin, admin_repository, "job_id" => job.id)

      expect {
        expect(action.confirm!(user: admin)).to be true
      }.to have_enqueued_job(RunJob).with(newer.id)
      expect(action.reload.result).to eq(newer)
    end

    it "raises when there is no queued Run and no workflow_id or run_id was given" do
      job = build_job(state: "approved")
      action = pending_action_for(admin, admin_repository, "job_id" => job.id)

      expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /workflow_id or run_id is required/)
    end
  end

  describe "explicit workflow_id" do
    it "starts the Workflow from scratch when it is queued with no Runs at all" do
      job = build_job(state: "queued")
      workflow = build_workflow(job, workflow_state: "queued", unit_state: "queued")
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "workflow_id" => workflow.id)

      expect {
        expect(action.confirm!(user: admin)).to be true
      }.to change { workflow.runs.count }.from(0).to(1)

      expect(action.reload.result).to be_a(Run)
    end

    it "raises when the Workflow is running but has no queued Run to re-enqueue" do
      job = build_job
      workflow = build_workflow(job, workflow_state: "running", unit_state: "running")
      build_run(job, workflow, state: "running")
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "workflow_id" => workflow.id)

      expect { action.confirm!(user: admin) }.to raise_error(ArgumentError, /is running but has no queued Run/)
    end

    it "raises when the workflow_id is not active runtime work for the Job" do
      job = build_job
      other_job = build_job
      other_workflow = build_workflow(other_job)
      action = pending_action_for(admin, admin_repository, "job_id" => job.id, "workflow_id" => other_workflow.id)

      expect { action.confirm!(user: admin) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
