require "rails_helper"

# Under MySQL's REPEATABLE READ a transaction's plain reads answer from the
# snapshot its first plain read fixed. Lineage.lock! makes plain discovery
# reads before it waits on the row locks, so whatever a concurrent
# transaction commits while this one waits is invisible to plain reads after
# the lock -- a Run was executed twice in production that way. Locking reads
# return the latest committed rows.
#
# SQLite has no snapshot, so these examples stage it: an in-memory copy read
# before the concurrent commit, a plain reload pinned to that copy
# (pin_plain_reload), or plain relation reads limited to the rows the
# snapshot held (with_stale_snapshot, spec/support/stale_snapshot.rb).
RSpec.describe "Decisions after a row lock read the committed rows" do
  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }
  let(:step) { workflow.steps.create!(kind: "grader", position: 99, state: "running", started_at: 2.minutes.ago) }
  let!(:run) do
    step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
                      state: "running", started_at: 2.minutes.ago)
  end

  before { workflow.update_columns(state: "running", started_at: 3.minutes.ago) }

  describe Lineage do
    it "refreshes a stale copy from the locked row and keeps its unsaved changes" do
      stale = Run.find(run.id)
      run.update_columns(state: "succeeded", finished_at: Time.current, execution_attempt: 3)
      stale.prompt = "unsaved"

      Lineage.lock!(stale)

      expect(stale).to have_attributes(state: "succeeded", execution_attempt: 3, prompt: "unsaved")
      expect(stale.changed).to eq([ "prompt" ])
    end

    it "keeps a state the caller changed and has not saved" do
      stale = Run.find(run.id)
      run.update_columns(state: "succeeded", finished_at: Time.current)
      stale.state = "failed"

      Lineage.lock!(stale)

      expect(stale.state).to eq("failed")
    end

    it "refreshes the ancestors the record carries in memory" do
      stale = Run.find(run.id)
      stale.step.workflow
      Step.where(id: step.id).update_all(state: "failed")
      Workflow.where(id: workflow.id).update_all(state: "failed")

      Lineage.lock!(stale)

      expect(stale.step.state).to eq("failed")
      expect(stale.step.workflow.state).to eq("failed")
    end
  end

  describe "an AASM event fired on a copy read before a concurrent transition" do
    it "decides from the committed state instead of overwriting it" do
      stale = Run.find(run.id)
      run.update_columns(state: "succeeded", finished_at: Time.current)

      expect(stale.cancel!).to be(false)

      expect(run.reload).to be_succeeded
      expect(StateTransition.where(subject: run, event_name: "cancel")).to be_empty
    end
  end

  describe Run, "#cancel_columns_if_active!" do
    it "does not overwrite a Run that finished after it was read" do
      stale = Run.find(run.id)
      run.update_columns(state: "succeeded", finished_at: Time.current)

      expect(stale.cancel_columns_if_active!).to be(false)
      expect(stale.cancel_without_step_cascade!).to be(false)

      expect(run.reload).to be_succeeded
      expect(StateTransition.where(subject: run, event_name: "cancel")).to be_empty
    end

    it "cancels a Run that is still active" do
      expect(Run.find(run.id).cancel_columns_if_active!).to be(true)
      expect(run.reload).to be_cancelled
    end
  end

  describe Workflow, "#record_run_failure!" do
    before { allow(AppSetting).to receive(:max_job_failures).and_return(10) }

    it "counts a failure another transaction recorded while this one waited" do
      stale = Workflow.find(workflow.id)
      Workflow.find(workflow.id).record_run_failure!
      pin_plain_reload(stale)

      stale.record_run_failure!

      expect(workflow.reload.failure_count).to eq(2)
    end
  end

  describe StepDispatcher, ".create_run_and_enqueue" do
    let(:step) { workflow.steps.create!(kind: "grader", position: 99, state: "queued") }
    let!(:run) { nil }

    it "does not create a second Run when a concurrent creator committed one while it waited" do
      step
      snapshot = Run.where(step_id: step.id).pluck(:id)
      existing = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider)

      with_stale_snapshot(Run => snapshot) do
        expect(StepDispatcher.create_run_and_enqueue(step, workflow)).to be_nil
      end

      expect(step.runs.reload.map(&:id)).to eq([ existing.id ])
    end
  end

  describe WorkEngine::RepairExecutor, "scheduling an automatic retry" do
    let(:step) do
      workflow.steps.create!(kind: "grader", position: 99, state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    end
    let!(:run) do
      step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: workflow.agent_provider,
                        state: "failed", started_at: 2.minutes.ago, finished_at: 1.minute.ago)
    end

    before { workflow.update_columns(state: "failed", finished_at: 1.minute.ago) }

    def retry_failed_step_plan
      WorkEngine::RepairPlanner::Plan.new(
        issue_kind: "failed_step_retryable", action: "retry_failed_step", auto_executable: true,
        target_type: "Run", target_id: run.id, affected_ids: {}, execution_steps: [], preconditions: {},
        reason: "test"
      )
    end

    it "sees an attempt a concurrent scheduler committed while it waited on the Workflow lock" do
      concurrent = nil
      allow(Lineage).to receive(:lock!).and_wrap_original do |original, record|
        result = original.call(record)
        if record.is_a?(Workflow) && record.id == workflow.id && concurrent.nil?
          concurrent = AutoRetryAttempt.create!(
            job: job, workflow: workflow, run: run, agent_provider: workflow.agent_provider || "claude",
            failure_classification: "unknown", retry_kind: "failed_step", attempt_number: 1,
            scheduled_at: 1.minute.from_now
          )
        end
        result
      end

      execution = with_stale_snapshot(AutoRetryAttempt => []) do
        WorkEngine::RepairExecutor.call(result: Struct.new(:repair_plans).new([ retry_failed_step_plan ])).sole
      end

      expect(concurrent).to be_present
      expect(execution.status).to eq("skipped")
      expect(AutoRetryAttempt.where(workflow: workflow).pluck(:id)).to eq([ concurrent.id ])
    end
  end
end
