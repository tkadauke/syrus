require "rails_helper"

RSpec.describe ReapStaleRunsJob do
  let(:job) { Factories.job }

  # Build a Run in `running` state with the given heartbeat age.
  # Stale (> 30 min) → reapable. Fresh → leave alone.
  def running_run(heartbeat_age:)
    run = Run.create!(job: Factories.job, trigger_kind: "initial")
    run.update_columns(
      state: "running",
      started_at: heartbeat_age.ago,
      last_heartbeat_at: heartbeat_age.ago
    )
    run
  end

  def inline_workflow_runs
    workflow = Workflow.create!(job: job, trigger_kind: "initial")
    root_step = Step.create!(workflow: workflow, kind: "prepare", position: 0)
    inline_step = Step.create!(workflow: workflow, kind: "implement", position: 1)
    root_step.update!(next_step_id: inline_step.id)

    root_run = root_step.runs.create!(job: job, trigger_kind: "initial")
    root_run.update_columns(
      state: "succeeded",
      started_at: 5.minutes.ago,
      finished_at: 4.minutes.ago
    )

    age = ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds
    inline_run = inline_step.runs.create!(job: job, trigger_kind: "initial")
    inline_run.update_columns(
      state: "running",
      started_at: age.ago,
      last_heartbeat_at: age.ago
    )

    [ workflow, root_run, inline_run ]
  end

  describe "#perform" do
    it "marks a run with stale heartbeat as failed" do
      run = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes)
      described_class.perform_now
      expect(run.reload.state).to eq("failed")
    end

    it "sets agent_outcome to worker_died" do
      run = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes)
      described_class.perform_now
      expect(run.reload.agent_outcome).to eq("worker_died")
    end

    it "does not enqueue retry workflows while reaping a stale heartbeat" do
      run = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes)

      expect {
        described_class.perform_now
      }.not_to change { Workflow.where(job: run.job, trigger_kind: "retry").count }

      expect(run.reload.agent_outcome).to eq("worker_died")
    end

    it "sets finished_at" do
      run = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes)
      freeze_time do
        described_class.perform_now
        expect(run.reload.finished_at).to eq(Time.current)
      end
    end

    it "leaves a freshly-heartbeated run alone (recent chunks)" do
      run = running_run(heartbeat_age: 30.seconds)
      described_class.perform_now
      expect(run.reload.state).to eq("running")
    end

    it "leaves alone a run mid-long-tool-call (heartbeat under threshold)" do
      run = running_run(heartbeat_age: 10.minutes)
      described_class.perform_now
      expect(run.reload.state).to eq("running")
    end

    it "ignores non-running runs even with very old timestamps" do
      run = Run.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "succeeded", started_at: 1.hour.ago, finished_at: 30.minutes.ago)
      described_class.perform_now
      expect(run.reload.state).to eq("succeeded")
    end

    it "handles workspace cleanup errors without aborting the job" do
      # Workspace teardown happens via Workflow's terminal-state
      # callback now (Step.fail → Workflow.fail → cleanup_workspace!)
      # — but the same robustness applies: if cleanup raises, the
      # reap should still leave the Run in `failed`.
      run = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes)
      allow(WorkflowWorkspace).to receive(:cleanup_for).and_raise(RuntimeError, "no such worktree")
      expect { described_class.perform_now }.not_to raise_error
      expect(run.reload.state).to eq("failed")
    end

    it "reaps multiple stale runs in one pass" do
      r1 = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes)
      r2 = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 60.minutes)
      described_class.perform_now
      expect(r1.reload.state).to eq("failed")
      expect(r2.reload.state).to eq("failed")
    end

    describe "fast path: SolidQueue::ProcessPrunedError (post-deploy zombies)" do
      # SolidQueue tables aren't loaded in the test DB (single-database
      # test setup), so we stub the helper that reads them. The
      # behavior under test is the *decision* given a set of pruned
      # Run ids — what SQ returns is exercised in production.
      def stub_pruned(*run_ids)
        allow_any_instance_of(described_class)
          .to receive(:pruned_run_ids_from_solid_queue)
          .and_return(run_ids.map(&:to_i))
      end

      def stub_pruned_roots(*run_ids)
        allow_any_instance_of(described_class)
          .to receive(:pruned_root_run_ids_from_solid_queue)
          .and_return(run_ids.map(&:to_i))
      end

      it "reaps a running Run whose SQ::Job was failed with ProcessPrunedError, even if heartbeat is fresh" do
        # Fresh heartbeat — heartbeat-stale path WOULD NOT reap. Only
        # the SQ-pruned signal does.
        run = running_run(heartbeat_age: 30.seconds)
        stub_pruned(run.id)
        described_class.perform_now
        expect(run.reload.state).to eq("failed")
        expect(run.agent_outcome).to eq("worker_died")
      end

      it "ignores SQ-pruned ids that don't correspond to a still-running Run (race-safe)" do
        run = running_run(heartbeat_age: 30.seconds)
        run.update_columns(state: "failed", finished_at: 1.minute.ago)
        stub_pruned(run.id)
        expect { described_class.perform_now }.not_to change { run.reload.state }
      end

      it "no-ops when SQ has no pruned RunJobs (the common case)" do
        running = running_run(heartbeat_age: 30.seconds)
        stub_pruned
        described_class.perform_now
        expect(running.reload.state).to eq("running")
      end

      it "still falls through to heartbeat-stale reaping after the SQ-pruned pass" do
        sq_pruned = running_run(heartbeat_age: 30.seconds)
        old = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 1.minute)
        stub_pruned(sq_pruned.id)
        described_class.perform_now
        expect(sq_pruned.reload.state).to eq("failed")  # via SQ signal
        expect(old.reload.state).to eq("failed")        # via heartbeat-stale
      end

      it "reaps a running inline Run when the owning root RunJob was pruned" do
        _workflow, root_run, inline_run = inline_workflow_runs
        stub_pruned_roots(root_run.id)

        described_class.perform_now

        expect(inline_run.reload.state).to eq("failed")
        expect(inline_run.agent_outcome).to eq("worker_died")
      end
    end

    describe "orphan-run path: Run :running but no SQ::Job" do
      # SolidQueue tables aren't loaded in the test DB, so we stub the
      # active-set lookup. The behavior under test is the *decision*
      # given a set of "active" Run ids vs. the candidate set — what
      # SQ actually returns is exercised in production.
      def stub_active_run_ids(*ids)
        allow_any_instance_of(described_class)
          .to receive(:active_run_job_run_ids)
          .and_return(ids.map(&:to_i).to_set)
      end

      def stub_active_root_run_ids(*ids)
        allow_any_instance_of(described_class)
          .to receive(:active_run_job_root_run_ids)
          .and_return(ids.map(&:to_i))
      end

      it "reaps a Run past the grace window whose SQ::Job has disappeared" do
        run = running_run(heartbeat_age: ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds)
        stub_active_run_ids  # no active SQ::Jobs reference this Run
        described_class.perform_now
        expect(run.reload.state).to eq("failed")
        expect(run.agent_outcome).to eq("worker_died")
      end

      it "leaves a Run alone when its SQ::Job is still active" do
        run = running_run(heartbeat_age: ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds)
        stub_active_run_ids(run.id)  # pretend SQ::Job for this Run is alive
        described_class.perform_now
        expect(run.reload.state).to eq("running")
      end

      it "leaves a running inline Run alone when an active root RunJob owns its Workflow" do
        _workflow, root_run, inline_run = inline_workflow_runs
        stub_active_root_run_ids(root_run.id)

        described_class.perform_now

        expect(inline_run.reload.state).to eq("running")
      end

      it "leaves a brand-new Run alone (inside the grace window)" do
        # Just-created Run — SQ::Job enqueue race possible. Don't
        # reap even though the active-set lookup returns nothing.
        run = running_run(heartbeat_age: 30.seconds)
        stub_active_run_ids
        described_class.perform_now
        expect(run.reload.state).to eq("running")
      end

      it "ignores Runs in non-:running states even past the grace window" do
        run = Run.create!(job: job, trigger_kind: "initial")
        run.update_columns(state: "queued", started_at: 1.hour.ago)
        stub_active_run_ids
        expect { described_class.perform_now }.not_to change { run.reload.state }
      end
    end

    describe "orphan-workflow path: Workflow :running but all descendants are terminal" do
      def terminal_rebase_workflow(job:, step_states:)
        workflow = Workflows::Rebase.instantiate(job: job)
        workflow.update!(
          state: "running",
          started_at: (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds).ago
        )

        workflow.steps.order(:position).zip(step_states).each do |step, state|
          step.update_columns(
            state: state,
            started_at: 5.minutes.ago,
            finished_at: 4.minutes.ago
          )
          run = step.runs.create!(job: job, trigger_kind: "rebase")
          run.update_columns(
            state: state,
            started_at: 5.minutes.ago,
            finished_at: 4.minutes.ago
          )
        end

        workflow
      end

      it "succeeds a running workflow whose last meaningful terminal step succeeded" do
        repo = Factories.repository(auto_merge_enabled: true)
        job = Factories.job_record(user: repo.user, repository: repo, state: "implemented", pr_number: 12)
        job.approve!(via: "github_review")
        job.save!
        workflow = terminal_rebase_workflow(job: job, step_states: %w[succeeded succeeded succeeded])

        allow(LandingQueueProcessor).to receive(:try_land!)

        described_class.perform_now

        expect(workflow.reload).to be_succeeded
        expect(LandingQueueProcessor).to have_received(:try_land!).with(job)
      end

      it "fails a running workflow whose last meaningful terminal step failed" do
        workflow = terminal_rebase_workflow(job: job, step_states: %w[succeeded failed cancelled])

        described_class.perform_now

        expect(workflow.reload).to be_failed
      end

      it "leaves a running workflow alone while a descendant run is still active" do
        workflow = terminal_rebase_workflow(job: job, step_states: %w[succeeded succeeded succeeded])
        last_run = workflow.steps.order(:position).last.runs.last
        last_run.update_columns(state: "running", finished_at: nil, last_heartbeat_at: 30.seconds.ago)

        described_class.perform_now

        expect(workflow.reload).to be_running
      end
    end
  end

  describe "Run.stale scope" do
    it "includes a running run whose last_heartbeat_at is past the threshold" do
      run = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 1.minute)
      expect(Run.stale).to include(run)
    end

    it "includes a running run with no heartbeat but an old started_at" do
      run = Run.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "running", started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 1.minute).ago, last_heartbeat_at: nil)
      expect(Run.stale).to include(run)
    end

    it "excludes a running run with a recent heartbeat" do
      run = running_run(heartbeat_age: 30.seconds)
      expect(Run.stale).not_to include(run)
    end

    it "excludes a non-running run regardless of timestamps" do
      run = Run.create!(job: job, trigger_kind: "initial")
      run.update_columns(state: "failed", started_at: 1.hour.ago, finished_at: 30.minutes.ago)
      expect(Run.stale).not_to include(run)
    end
  end
end
