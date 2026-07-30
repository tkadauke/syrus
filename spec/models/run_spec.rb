require "rails_helper"

RSpec.describe Run do
  let(:job) { Factories.job }

  describe "agent diff storage" do
    it "uses MEDIUMTEXT-sized storage for captured diffs" do
      expect(described_class.columns_hash.fetch("agent_diff").limit).to eq(16.megabytes - 1)
    end

    it "persists diffs larger than MySQL TEXT" do
      large_diff = +"diff --git a/big.txt b/big.txt\n"
      large_diff << "+#{'x' * 70.kilobytes}\n"

      run = job.initial_run
      run.update!(agent_diff: large_diff)

      expect(run.reload.agent_diff.bytesize).to eq(large_diff.bytesize)
    end
  end

  describe "iteration column" do
    it "defaults iteration to 1" do
      expect(job.initial_run.iteration).to eq(1)
    end

    it "mirrors the step iteration when the dispatcher creates a run" do
      workflow = Workflow.create!(job: job, trigger_kind: "initial")
      step = Step.create!(workflow: workflow, kind: "implement", position: 0, iteration: 3)

      run = StepDispatcher.create_run_and_enqueue(step, workflow)

      expect(run.iteration).to eq(3)
    end
  end

  describe "AASM state machine (was Job's)" do
    it "starts queued" do
      expect(job.initial_run).to be_queued
    end

    it "queued → running via start, sets started_at" do
      run = job.initial_run
      freeze_time do
        run.start!
        expect(run.state).to eq("running")
        expect(run.started_at).to eq(Time.current)
      end
    end

    it "running → succeeded via succeed, sets finished_at" do
      run = job.initial_run
      run.start!
      freeze_time do
        run.succeed!
        expect(run.state).to eq("succeeded")
        expect(run.finished_at).to eq(Time.current)
      end
    end

    it "queued → cancelled via cancel" do
      run = job.initial_run
      expect { run.cancel! }.to change(run, :state).from("queued").to("cancelled")
      expect(run.finished_at).to be_present
    end

    it "running → failed via fail" do
      run = job.initial_run
      run.start!
      expect { run.fail! }.to change(run, :state).from("running").to("failed")
    end

    it "queued → failed via fail (pre-flight failure)" do
      run = job.initial_run
      expect { run.fail! }.to change(run, :state).from("queued").to("failed")
    end

    it "cannot succeed without starting" do
      run = job.initial_run
      expect(run.may_succeed?).to be false
    end

    it "cannot cancel a terminal run" do
      run = job.initial_run
      run.start!; run.succeed!
      expect(run.may_cancel?).to be false
    end
  end

  describe "trigger_kind" do
    it "validates inclusion" do
      run = Run.new(job: job, trigger_kind: "weird")
      expect(run).not_to be_valid
    end

    it "exposes #initial?" do
      expect(job.initial_run).to be_initial
    end

    it "is not initial for other triggers" do
      followup = Run.create!(job: job, trigger_kind: "pr_comment")
      expect(followup).not_to be_initial
    end

    it "accepts 'rebase' as a valid trigger" do
      r = Run.new(job: job, trigger_kind: "rebase")
      expect(r).to be_valid
    end

    it "accepts 'auto_merge' as a valid trigger" do
      r = Run.new(job: job, trigger_kind: "auto_merge")
      expect(r).to be_valid
    end

    it "validates agent_provider" do
      r = Run.new(job: job, trigger_kind: "initial", agent_provider: "oracle")
      expect(r).not_to be_valid
      expect(r.errors[:agent_provider]).to be_present
    end

    it "exposes #rebase?" do
      r = Run.create!(job: job, trigger_kind: "rebase")
      expect(r).to be_rebase
      expect(job.initial_run).not_to be_rebase
    end
  end

  describe "execution ownership" do
    it "defaults the execution owner from the job" do
      run = Run.create!(job: job, trigger_kind: "pr_comment")

      expect(run.user).to eq(job.user)
    end

    it "rejects an execution owner from another user's job" do
      other_user = Factories.user
      run = Run.new(job: job, trigger_kind: "pr_comment", user: other_user)

      expect(run).not_to be_valid
      expect(run.errors[:user]).to include("must match the Job owner")
    end

    it "rejects a step from another user's workflow" do
      other_job = Factories.job
      other_workflow = Workflow.create!(job: other_job, trigger_kind: "initial")
      other_step = Step.create!(workflow: other_workflow, kind: "implement", position: 0)

      run = Run.new(job: job, step: other_step, trigger_kind: "initial")

      expect(run).not_to be_valid
      expect(run.errors[:step]).to include("must belong to the same Job as the Run")
      expect(run.errors[:user]).to include("must match the Workflow owner")
    end
  end

  describe "scopes" do
    it "active = queued + running" do
      a = job.initial_run
      Run.create!(job: job, trigger_kind: "pr_comment")  # queued
      a.start!; a.save!
      failed = Run.create!(job: job, trigger_kind: "manual")
      failed.update_columns(state: "failed")
      expect(job.runs.active.count).to eq(2)
    end

    it "terminal = succeeded + failed + cancelled" do
      a = job.initial_run
      a.start!; a.succeed!; a.save!
      Run.create!(job: job, trigger_kind: "pr_comment")  # queued, not terminal
      expect(job.runs.terminal.count).to eq(1)
    end
  end

  describe "auto-enqueue RunJob on commit" do
    around do |example|
      old_in_run_job = Thread.current[:syrus_in_run_job]
      old_current_run = Thread.current[:syrus_current_run]
      Thread.current[:syrus_in_run_job] = nil
      Thread.current[:syrus_current_run] = nil
      example.run
    ensure
      Thread.current[:syrus_in_run_job] = old_in_run_job
      Thread.current[:syrus_current_run] = old_current_run
    end

    it "enqueues a RunJob with the new Run's id" do
      job  # force creation outside the expect block so its initial-Run
      # enqueue isn't counted against this assertion
      expect {
        Run.create!(job: job, trigger_kind: "pr_comment")
      }.to have_enqueued_job(RunJob).with { |id| expect(id).to be_a(Integer) }
    end

    it "does not enqueue if the Run is created in a terminal state" do
      job
      expect {
        Run.create!(job: job, trigger_kind: "manual", state: "succeeded")
      }.not_to have_enqueued_job(RunJob)
    end

    it "enqueues with the job's SolidQueue priority for a high-priority job" do
      high_job = Factories.job(priority: "high")
      expected_priority = Job::PRIORITY_TO_SQ["high"]
      Run.create!(job: high_job, trigger_kind: "pr_comment")
      run_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == RunJob }
      expect(run_jobs.last[:priority]).to eq(expected_priority)
    end

    it "enqueues with medium SolidQueue priority by default" do
      job
      Run.create!(job: job, trigger_kind: "pr_comment")
      run_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == RunJob }
      expect(run_jobs.last[:priority]).to eq(Job::PRIORITY_TO_SQ["medium"])
    end

    it "enqueues AutoMerge workflow runs on the merges queue" do
      job
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      workflow = Workflows::AutoMerge.instantiate(job: job)
      step = workflow.steps.first

      expect {
        step.runs.create!(
          job: job,
          trigger_kind: workflow.trigger_kind,
          agent_provider: workflow.agent_provider
        )
      }.to have_enqueued_job(RunJob).on_queue("merges")
    end

    it "enqueues Rebase workflow runs on the merges queue" do
      job
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      workflow = Workflows::Rebase.instantiate(job: job)
      step = workflow.steps.first

      expect {
        step.runs.create!(
          job: job,
          trigger_kind: workflow.trigger_kind,
          agent_provider: workflow.agent_provider
        )
      }.to have_enqueued_job(RunJob).on_queue("merges")
    end

    it "enqueues StackRebase workflow runs on the merges queue" do
      job
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      workflow = Workflows::StackRebase.instantiate(job: job)
      step = workflow.steps.first

      expect {
        step.runs.create!(
          job: job,
          trigger_kind: workflow.trigger_kind,
          agent_provider: workflow.agent_provider
        )
      }.to have_enqueued_job(RunJob).on_queue("merges")
    end

    it "enqueues Initial workflow runs on the runs queue" do
      job
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      workflow = Workflows::Initial.instantiate(job: job)
      step = workflow.steps.first

      expect {
        step.runs.create!(
          job: job,
          trigger_kind: workflow.trigger_kind,
          agent_provider: workflow.agent_provider
        )
      }.to have_enqueued_job(RunJob).on_queue("runs")
    end

    it "enqueues when a RunJob thread creates a Run for a different workflow" do
      current_run = job.initial_run
      other_job = Factories.job
      other_workflow = Workflow.create!(
        job: other_job,
        trigger_kind: "rebase",
        agent_provider: other_job.agent_provider
      )
      other_step = Step.create!(workflow: other_workflow, kind: "agent_rebase", position: 0)
      Thread.current[:syrus_in_run_job] = true
      Thread.current[:syrus_current_run] = current_run

      expect {
        other_step.runs.create!(job: other_job, trigger_kind: "rebase")
      }.to have_enqueued_job(RunJob).with { |id|
        expect(Run.find(id).workflow_id).to eq(other_workflow.id)
      }
    end

    it "does not enqueue when a RunJob thread creates another Run in the current workflow" do
      current_run = job.initial_run
      next_step = Step.create!(workflow: current_run.workflow, kind: "implement", position: 99)
      Thread.current[:syrus_in_run_job] = true
      Thread.current[:syrus_current_run] = current_run

      expect {
        next_step.runs.create!(job: job, trigger_kind: "initial")
      }.not_to have_enqueued_job(RunJob)
    end

    it "enqueues a workflow-backed Run when there is no current RunJob thread" do
      current_run = job.initial_run
      next_step = Step.create!(workflow: current_run.workflow, kind: "implement", position: 99)

      expect {
        next_step.runs.create!(job: job, trigger_kind: "initial")
      }.to have_enqueued_job(RunJob).with { |id|
        expect(Run.find(id).workflow_id).to eq(current_run.workflow_id)
      }
    end
  end

  describe "transcript pruning on success" do
    it "clears ClaudeSession transcript_jsonl when the Run transitions to succeeded" do
      run = job.initial_run
      run.start!; run.save!
      session = ClaudeSession.create!(resumable: run, session_id: "abc", transcript_jsonl: "big payload")
      run.succeed!; run.save!
      expect(session.reload.transcript_jsonl).to be_nil
    end

    it "does not clear transcript when the Run fails" do
      run = job.initial_run
      run.start!; run.save!
      session = ClaudeSession.create!(resumable: run, session_id: "abc", transcript_jsonl: "big payload")
      run.fail!; run.save!
      expect(session.reload.transcript_jsonl).to eq("big payload")
    end

    it "is a no-op when the Run has no ClaudeSession" do
      run = job.initial_run
      run.start!; run.save!
      run.succeed!; run.save!
      expect(run.reload.state).to eq("succeeded")
    end
  end

  describe "failure dispatch" do
    it "routes failed Runs through StepDispatcher.fail_from" do
      workflow = Workflow.create!(job: job, trigger_kind: "initial")
      step = Step.create!(workflow: workflow, kind: "implement", position: 0, state: "running")
      run = step.runs.create!(job: job, trigger_kind: "initial", state: "running")

      expect(StepDispatcher).to receive(:fail_from).with(step).at_least(:once)

      run.fail!
      run.save!
    end
  end

  describe "in-place worker_died step retry" do
    let(:workflow) { Workflow.create!(job: job, trigger_kind: "initial") }
    let(:step) { Step.create!(workflow: workflow, kind: "grader", position: 0, state: "running") }

    def make_worker_died_run!(step)
      r = step.runs.create!(job: job, trigger_kind: "initial", state: "failed",
                             agent_outcome: "worker_died", finished_at: Time.current)
      r.create_run_failure_classification!(
        classification: "worker_died",
        retryable: true,
        classified_at: Time.current
      )
      r
    end

    it "creates a new Run on the same step and keeps the step running on the first worker_died" do
      run = step.runs.create!(job: job, trigger_kind: "initial", state: "running")

      run.agent_outcome = "worker_died"
      run.fail!
      run.save!

      expect(step.reload).not_to be_failed
      expect(step.runs.where(state: "queued").count).to eq(1)
    end

    it "keeps creating retry runs until the budget is exhausted" do
      make_worker_died_run!(step)
      make_worker_died_run!(step)

      run = step.runs.create!(job: job, trigger_kind: "initial", state: "running")
      run.agent_outcome = "worker_died"
      run.fail!
      run.save!

      expect(step.reload).not_to be_failed
      expect(step.runs.where(state: "queued").count).to eq(1)
    end

    it "fails the step normally once WORKER_DIED_STEP_MAX_RETRIES prior worker_died runs exist" do
      Run::WORKER_DIED_STEP_MAX_RETRIES.times { make_worker_died_run!(step) }

      run = step.runs.create!(job: job, trigger_kind: "initial", state: "running")
      run.agent_outcome = "worker_died"
      run.fail!
      run.save!

      expect(step.reload).to be_failed
      expect(step.runs.where(state: "queued").count).to eq(0)
    end

    it "skips the in-place retry for non-worker_died failures and fails the step immediately" do
      run = step.runs.create!(job: job, trigger_kind: "initial", state: "running")
      run.agent_outcome = "agent_max_turns"
      run.fail!
      run.save!

      expect(step.reload).to be_failed
      expect(step.runs.where(state: "queued").count).to eq(0)
    end

    it "does not call StepDispatcher.fail_from when a retry run is created" do
      run = step.runs.create!(job: job, trigger_kind: "initial", state: "running")
      run.agent_outcome = "worker_died"

      expect(StepDispatcher).not_to receive(:fail_from)

      run.fail!
      run.save!
    end
  end

  describe "#terminal?" do
    it "is false for queued and running" do
      run = job.initial_run
      expect(run).not_to be_terminal
      run.start!
      expect(run).not_to be_terminal
    end

    it "is true for succeeded, failed, cancelled" do
      [ ->(r) { r.start!; r.succeed! }, ->(r) { r.fail! }, ->(r) { r.cancel! } ].each do |drive|
        run = Run.create!(job: Factories.job, trigger_kind: "pr_comment")
        drive.call(run)
        expect(run).to be_terminal
      end
    end
  end

  describe "resume-worker queue routing (#enqueue_run_job)" do
    include ActiveJob::TestHelper

    let(:run) { job.initial_run }
    let(:workflow) { run.workflow }

    def fresh_worker!(hostname)
      InstanceVersion.create!(hostname: hostname, role: "worker", version: "test-sha",
                              started_at: Time.current, last_heartbeat_at: Time.current)
    end

    it "uses the normal :runs queue when no worker hostname is recorded" do
      run  # force Job/Run creation before clearing so factory noise is excluded
      clear_enqueued_jobs
      expect { run.reenqueue! }.to have_enqueued_job(RunJob).on_queue("runs")
    end

    it "routes to the pod's resume queue when the recorded worker is live" do
      workflow.update_column(:worker_hostname, "syrus-worker-1")
      fresh_worker!("syrus-worker-1")

      clear_enqueued_jobs
      expect { run.reenqueue! }.to have_enqueued_job(RunJob).on_queue("resume-syrus-worker-1")
    end

    it "falls back to :runs when the recorded worker is gone (no fresh instance)" do
      workflow.update_column(:worker_hostname, "syrus-worker-dead")

      clear_enqueued_jobs
      expect { run.reenqueue! }.to have_enqueued_job(RunJob).on_queue("runs")
    end
  end

  describe "Workflow#record_worker_hostname!" do
    it "stamps the current worker hostname exactly once" do
      workflow = job.initial_run.workflow
      allow(SyrusVersion).to receive(:hostname).and_return("syrus-worker-7")

      workflow.record_worker_hostname!
      expect(workflow.reload.worker_hostname).to eq("syrus-worker-7")

      # Idempotent: no redundant write when already stamped for this host.
      expect(workflow).not_to receive(:update_column)
      workflow.record_worker_hostname!
    end
  end
end
