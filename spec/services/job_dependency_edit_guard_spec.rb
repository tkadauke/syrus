require "rails_helper"

RSpec.describe JobDependencyEditGuard do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(state: "running", repository: repository, user: user) }
  let(:prerequisite) { Factories.job_record(state: "running", repository: repository, user: user, issue_number: 900) }

  def start_workflow(state: "running")
    Workflow.create!(job: job, trigger_kind: "initial", agent_provider: "claude", state: state).tap do |workflow|
      attach_work_unit(workflow, state: state)
    end
  end

  def add_dependency = JobDependency.create!(job: job, depends_on_job: prerequisite, source: "manual")

  it "does nothing when the start gate is met" do
    start_workflow
    Run.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude", state: "running")

    expect(described_class.enforce!(job)).to eq(:ok)
    expect(job.reload).to be_running
  end

  it "rejects, naming the active Run, when the gate is unmet and a Run is active" do
    start_workflow
    run = Run.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude", state: "running")
    add_dependency

    expect { described_class.enforce!(job) }
      .to raise_error(described_class::ActiveRunRejection, /#{run.slug}/)
  end

  it "holds the Job when hold_running is set" do
    workflow = start_workflow
    run = Run.create!(job: job, user: user, trigger_kind: "initial", agent_provider: "claude", state: "running")
    add_dependency

    expect(described_class.enforce!(job, hold_running: true, reason: "rewired")).to eq(:held)
    expect(run.reload).to be_cancelled
    expect(workflow.reload).to be_cancelled
    expect(job.reload.state).to eq("queued")
  end

  it "returns a running Job whose Workflow is blocked to the waiting state" do
    workflow = start_workflow(state: "blocked")
    add_dependency

    # JobDependency's after_commit hook demotes the idle started Job.
    expect(job.reload.state).to eq("queued")
    expect(workflow.reload).to be_cancelled
  end

  it "makes a held Job schedulable again once the dependency is satisfied" do
    start_workflow(state: "blocked")
    add_dependency
    expect(job.reload.state).to eq("queued")

    prerequisite.update!(state: "closed", closure_reason: "pr_merged")

    expect(job.reload.dependencies_satisfied_for_execution?).to be true
    expect(job).to be_may_start_running
  end
end
