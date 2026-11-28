require "rails_helper"

RSpec.describe PendingActions::HoldJob do
  let!(:admin) { Factories.user(admin: true) }
  let(:repository) { Factories.repository(user: admin) }
  let(:job) { Factories.job_record(state: "running", repository: repository, user: admin, pr_number: 77) }
  let(:prerequisite) { Factories.job_record(state: "running", repository: repository, user: admin, issue_number: 900) }
  let!(:workflow) do
    Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", state: "running").tap do |record|
      attach_work_unit(record, state: "running")
    end
  end
  let!(:run) { Run.create!(job: job, user: admin, trigger_kind: "initial", agent_provider: "claude", state: "running") }

  def pending_action_for(**payload)
    ChatSession.create!(user: admin, repository: repository).pending_actions.create!(
      action: "hold_job", requested_by: "agent", reason: "running before its turn", payload: payload
    )
  end

  def add_unsatisfied_dependency
    JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")
  end

  it "cancels active work, releases locks, returns the Job to waiting and keeps the Job open with its PR" do
    add_unsatisfied_dependency
    action = pending_action_for("job_id" => job.id)

    action.confirm!(user: admin)

    expect(action.reload).to be_confirmed
    expect(run.reload).to be_cancelled
    expect(workflow.reload).to be_cancelled
    expect(workflow.work_unit.work_unit_locks.active).to be_empty
    expect(job.reload).to have_attributes(state: "queued", pr_number: 77, closure_reason: nil)
    expect(job).not_to be_closed
  end

  it "moves a Job without a PR to backlog on request" do
    job.update!(pr_number: nil)
    action = pending_action_for("job_id" => job.id, "to_backlog" => true)

    action.confirm!(user: admin)

    expect(job.reload.state).to eq("backlog")
  end

  it "rejects a Job with no active work" do
    add_unsatisfied_dependency
    run.update!(state: "cancelled")
    workflow.update!(state: "cancelled")

    expect { pending_action_for("job_id" => job.id) }
      .to raise_error(ActiveRecord::RecordInvalid, /no active Runs or Workflows/)
  end

  it "rejects a Job whose dependencies are all satisfied" do
    expect { pending_action_for("job_id" => job.id) }
      .to raise_error(ActiveRecord::RecordInvalid, /nothing to wait for/)
  end

  it "rejects to_backlog for a Job that already has a PR" do
    expect { pending_action_for("job_id" => job.id, "to_backlog" => true) }
      .to raise_error(ActiveRecord::RecordInvalid, /cannot be moved to backlog/)
  end

  it "requires a reason" do
    expect do
      ChatSession.create!(user: admin, repository: repository).pending_actions.create!(
        action: "hold_job", requested_by: "agent", reason: "", payload: { "job_id" => job.id }
      )
    end.to raise_error(ActiveRecord::RecordInvalid, /reason/i)
  end

  it "writes an audit entry on the Job's latest Run" do
    add_unsatisfied_dependency
    action = pending_action_for("job_id" => job.id)

    action.confirm!(user: admin)

    expect(JobLog.where(run: run).pluck(:chunk).join).to include("[operator repair] held job").and include("running before its turn")
  end

  describe "owner authority" do
    let(:owner) { Factories.user }
    let(:owner_repository) { Factories.repository(user: owner) }
    let(:owned_job) { Factories.job_record(state: "running", repository: owner_repository, user: owner, pr_number: 78, issue_number: 910) }
    let(:owned_prerequisite) { Factories.job_record(state: "running", repository: owner_repository, user: owner, issue_number: 911) }
    let!(:owned_run) do
      Workflow.create!(job: owned_job, trigger_kind: "initial", agent_provider: "claude", state: "running").tap do |record|
        attach_work_unit(record, state: "running")
      end
      Run.create!(job: owned_job, user: owner, trigger_kind: "initial", agent_provider: "claude", state: "running")
    end

    def owner_hold(by:, **payload)
      ChatSession.create!(user: by, repository: owner_repository).pending_actions.create!(
        action: "hold_job", requested_by: "agent", reason: "running before its turn",
        payload: { "job_id" => owned_job.id }.merge(payload)
      )
    end

    it "lets a non-admin owner hold their own Job" do
      JobDependency.create!(job: owned_job, depends_on_job: owned_prerequisite, source: "manual")
      action = owner_hold(by: owner)

      action.confirm!(user: owner)

      expect(action.reload).to be_confirmed
      expect(owned_run.reload).to be_cancelled
      expect(owned_job.reload.state).to eq("queued")
    end

    it "refuses a non-admin who does not own the Job" do
      JobDependency.create!(job: owned_job, depends_on_job: owned_prerequisite, source: "manual")
      other = Factories.user
      owner_repository.repository_memberships.create!(user: other, role: "write")
      action = owner_hold(by: other)

      action.confirm!(user: other) rescue nil

      expect(action.reload).not_to be_confirmed
      expect(owned_run.reload).to be_running
    end

    it "applies a carried dependency edit and holds the Job in one confirmation" do
      action = owner_hold(by: owner, "dependency_edit" => {
        "tool" => "add_job_dependency", "arguments" => { "job_id" => owned_job.id, "depends_on_job_id" => owned_prerequisite.id }
      })
      expect(action).to be_valid

      action.confirm!(user: owner)

      expect(action.reload).to be_confirmed
      expect(owned_job.reload.depends_on_jobs).to contain_exactly(owned_prerequisite)
      expect(owned_run.reload).to be_cancelled
      expect(owned_job.state).to eq("queued")
    end
  end
end
