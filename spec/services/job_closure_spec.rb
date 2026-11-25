require "rails_helper"

# A Workflow never keeps working on a closed Job (formal/SyrusModel/JobClosure.lean,
# `ClosedQuiet`). Production: a rebase created moments before a merged PR was
# noticed started on the closed Job with a force-push queued, because closing
# only cancelled active Runs.
RSpec.describe JobClosure do
  let(:job) { Factories.job }

  def chain_workflow(trigger_kind: "initial")
    workflow = Workflow.create!(job: job, trigger_kind: trigger_kind, state: "running", started_at: Time.current)
    steps = %w[implement summarize pr_open].each_with_index.map do |kind, position|
      Step.create!(workflow: workflow, kind: kind, position: position)
    end
    steps.each_cons(2) { |a, b| a.update!(next_step_id: b.id) }
    [ workflow, steps ]
  end

  describe "a step that closes its own Workflow's Job" do
    it "ends the Workflow after that step and closes the Job when it finishes" do
      workflow, (first, second, third) = chain_workflow
      first.update_columns(state: "succeeded", finished_at: Time.current)
      workflow.request_job_closure!(job, "no_changes")

      StepDispatcher.advance_from(first.reload)

      expect([ second.reload.state, third.reload.state ]).to eq(%w[skipped skipped])
      expect(second.runs).to be_empty
      expect(workflow.reload).to be_succeeded
      expect(job.reload).to have_attributes(state: "closed", closure_reason: "no_changes")
    end

    it "still closes the Job when the Workflow fails instead" do
      workflow, _steps = chain_workflow
      workflow.request_job_closure!(job, "pr_merged")

      workflow.fail!
      workflow.save!

      expect(job.reload).to have_attributes(state: "closed", closure_reason: "pr_merged")
    end
  end

  # NY33: a cancelled Workflow locks its own Steps, then applies its pending
  # closure, which cancels the Job's other Workflows. Locking those after the
  # Steps inverted the row-lock order; they are now locked first.
  describe "cancelling a Workflow whose pending closure cancels a sibling" do
    it "locks the sibling Workflow before any Step" do
      other = job.reload.workflows.order(:id).last
      workflow, _steps = chain_workflow
      workflow.request_job_closure!(job, "pr_closed")
      checker = Syrus::LockOrder::Checker
      previous_mode = checker.mode
      checker.mode = :record
      before = checker.violations.size

      WorkUnits::WorkflowCancellation.cancel!(workflow.reload, reason: "operator_cancelled")

      expect(checker.violations.drop(before)).to be_empty
      expect(other.reload).to be_cancelled
      expect(job.reload).to have_attributes(state: "closed", closure_reason: "pr_closed")
    ensure
      checker.violations.slice!(before..) if before
      checker.mode = previous_mode
    end
  end

  describe "a Job closed by someone else while its Workflow is between steps" do
    it "does not start the next step and cancels the Workflow" do
      workflow, (first, second, _third) = chain_workflow
      first.update_columns(state: "succeeded", finished_at: Time.current)
      job.close_with_reason!("pr_closed")

      StepDispatcher.advance_from(first.reload)

      expect(second.reload.runs).to be_empty
      expect(workflow.reload).to be_cancelled
    end
  end

  describe ".close_now!" do
    it "cancels the Job's other active Workflows before closing it" do
      # Factories.job materializes the Job's initial Workflow and WorkUnit.
      other = job.reload.workflows.order(:id).last
      expect(other.work_unit).to be_active

      expect(described_class.close_now!(job, "pr_merged")).to be(true)

      expect(other.reload).to be_cancelled
      expect(job.reload).to have_attributes(state: "closed", closure_reason: "pr_merged")
    end
  end

  describe ".request!" do
    it "defers to an active landing Workflow working on the Job and closes it when that finishes" do
      landing = job.reload.workflows.order(:id).last
      expect(landing.work_unit).to be_active
      allow_any_instance_of(Workflow).to receive(:landing_workflow?) { |workflow| workflow.id == landing.id }

      expect(described_class.request!(job, "pr_merged")).to eq(:deferred)
      expect(job.reload).not_to be_closed
      expect(landing.reload.pending_job_closures_by_id).to eq(job.id => "pr_merged")

      WorkUnits::WorkflowCancellation.cancel!(landing, reason: "spec", artifacts: { "cancelled_reason" => "spec" })

      expect(job.reload).to have_attributes(state: "closed", closure_reason: "pr_merged")
    end

    it "closes now when no landing Workflow owns the Job" do
      expect(described_class.request!(job, "pr_closed")).to eq(:closed)
      expect(job.reload).to be_closed
    end
  end
end
