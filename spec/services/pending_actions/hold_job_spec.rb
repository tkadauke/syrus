require "rails_helper"

RSpec.describe PendingActions::HoldJob do
  let(:admin) { Factories.user(admin: true) }
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

  it "requires the acting user to be an admin" do
    member = Factories.user
    member_repository = Factories.repository(user: member)
    member_job = Factories.job_record(state: "running", repository: member_repository, user: member, issue_number: 910)
    dependency = Factories.job_record(state: "running", repository: member_repository, user: member, issue_number: 911)
    JobDependency.create!(job: member_job, depends_on_job: dependency, source: "manual")
    workflow = Workflow.create!(job: member_job, trigger_kind: "initial", agent_provider: "claude", state: "running")
    attach_work_unit(workflow, state: "running")
    action = ChatSession.create!(user: member, repository: member_repository).pending_actions.create!(
      action: "hold_job", requested_by: "agent", reason: "out of turn", payload: { "job_id" => member_job.id }
    )

    expect { action.confirm!(user: member) }.to raise_error(ArgumentError, /Admin access required/)
  end

  it "writes an audit entry on the Job's latest Run" do
    add_unsatisfied_dependency
    action = pending_action_for("job_id" => job.id)

    action.confirm!(user: admin)

    expect(JobLog.where(run: run).pluck(:chunk).join).to include("[operator repair] held job").and include("running before its turn")
  end
end
