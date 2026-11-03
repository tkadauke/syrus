require "rails_helper"

RSpec.describe "Auxiliary workflow release on terminal outcomes" do
  let(:user) { Factories.user }
  let(:repository) { Factories.repository(user: user) }
  let(:job) { Factories.job_record(user: user, repository: repository, state: "implemented") }

  Workflow::TriggerKind::NON_APPROVAL_BLOCKING_VALUES.each do |kind|
    describe kind do
      let(:workflow) do
        WorkUnits::Launcher.instantiate(kind: kind, job: job).tap do |wf|
          wf.update_columns(state: "running")
          wf.work_unit.work_unit_locks.create!(lock_key: "spec:aux:#{wf.id}")
        end
      end

      it "releases its WorkUnit and locks when blocked" do
        workflow.block!

        expect(workflow.work_unit.reload).to be_terminal
        expect(workflow.work_unit.work_unit_locks.active).to be_empty
        expect(job.reload.approval_blocking_runtime_work?).to be(false)
      end

      it "releases its WorkUnit and locks when failed" do
        workflow.fail!

        expect(workflow.work_unit.reload).to be_terminal
        expect(workflow.work_unit.work_unit_locks.active).to be_empty
      end

      it "releases its WorkUnit and locks when cancelled" do
        workflow.cancel!

        expect(workflow.work_unit.reload).to be_terminal
        expect(workflow.work_unit.work_unit_locks.active).to be_empty
      end

      it "repairs an already-blocked workflow with an active blocked WorkUnit" do
        workflow.update_columns(state: "blocked")
        workflow.work_unit.update_columns(state: "blocked", blocked_reason: "agent_cannot_proceed")

        WorkUnits::TerminalWorkflowSync.for_job(job.reload)

        expect(workflow.work_unit.reload).to be_terminal
        expect(workflow.work_unit.work_unit_locks.active).to be_empty
      end
    end
  end

  it "lets a blocked auxiliary workflow's job be approved in bulk" do
    wf = WorkUnits::Launcher.instantiate(kind: "visual_diff", job: job)
    wf.update_columns(state: "blocked")
    wf.work_unit.update_columns(state: "blocked", blocked_reason: "agent_cannot_proceed")

    result = Jobs::BulkApprover.call([ job ], via: "bulk", by_user: user)

    expect(result).to be_success
    expect(job.reload).to be_approved
  end

  it "does not block approval for a genuinely running auxiliary workflow" do
    wf = WorkUnits::Launcher.instantiate(kind: "visual_diff", job: job)
    wf.update_columns(state: "running")
    wf.work_unit.update_columns(state: "running")

    expect(job.reload.approval_blocking_runtime_work?).to be(false)
    expect(wf.work_unit.reload).to be_active
  end

  it "still blocks approval for an in-flight implement workflow" do
    wf = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    wf.update_columns(state: "running")
    wf.work_unit.update_columns(state: "running")

    expect(job.reload.approval_blocking_runtime_work?).to be(true)
  end
end
