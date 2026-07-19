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

  def enqueued_run_job_count(run)
    ActiveJob::Base.queue_adapter.enqueued_jobs.count { |entry| entry[:job] == RunJob && entry[:args] == [ run.id ] }
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

    it "reconciles a stale pr_open run that already opened its PR" do
      repo = Factories.repository
      job = Factories.job_record(repository: repo, state: "running", issue_number: 42, pr_number: 652, branch_name: "syrus/issue-42-1000")
      workflow = Workflow.create!(job: job, trigger_kind: "initial")
      workflow.update_columns(state: "running", started_at: 10.minutes.ago)
      step = Step.create!(workflow: workflow, kind: "pr_open", position: 0)
      step.update_columns(state: "running", started_at: 10.minutes.ago)
      run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      run.update_columns(
        state: "running",
        started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago,
        last_heartbeat_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago
      )
      JobLog.append!(run: run, chunk: 'pr_open: opened PR #652 ("Define canonical tracing parity fixtures for tests")')

      described_class.perform_now

      expect(run.reload).to be_succeeded
      expect(step.reload).to be_succeeded
      expect(workflow.reload).to be_succeeded
      expect(job.reload).to be_implemented
    end

    it "reconciles a stale pr_open run that already pushed an existing PR" do
      repo = Factories.repository
      job = Factories.job_record(repository: repo, state: "running", issue_number: 42, pr_number: 652, branch_name: "syrus/issue-42-1000")
      workflow = Workflow.create!(job: job, trigger_kind: "retry")
      workflow.update_columns(state: "running", started_at: 10.minutes.ago)
      step = Step.create!(workflow: workflow, kind: "pr_open", position: 0)
      step.update_columns(state: "running", started_at: 10.minutes.ago)
      run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind)
      ActiveJob::Base.queue_adapter.enqueued_jobs.clear
      run.update_columns(
        state: "running",
        started_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago,
        last_heartbeat_at: (Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes).ago
      )
      JobLog.append!(run: run, chunk: "pr_open: branch pushed for existing PR #652")

      described_class.perform_now

      expect(run.reload).to be_succeeded
      expect(step.reload).to be_succeeded
      expect(workflow.reload).to be_succeeded
      expect(job.reload).to be_implemented
    end

    it "schedules a missing retry for a recent already-failed deploy interruption" do
      workflow = job.latest_workflow
      agent_step = workflow.steps.find_by!(kind: "implement")
      agent_run = agent_step.runs.create!(
        job: job,
        trigger_kind: workflow.trigger_kind,
        agent_provider: "claude",
        state: "failed",
        agent_outcome: "worker_died",
        finished_at: 10.minutes.ago
      )
      ClaudeSession.create!(
        resumable: agent_run,
        provider: "claude",
        session_id: "deploy-interrupted-thread",
        transcript_jsonl: "{}\n"
      )
      agent_step.update_columns(state: "failed", finished_at: 10.minutes.ago)
      workflow.update_columns(state: "failed", finished_at: 10.minutes.ago)
      job.update_columns(state: "failed")

      expect {
        described_class.perform_now
      }.to change { AutoRetryAttempt.where(retry_kind: "resume_failed_step").count }.by(1)

      attempt = AutoRetryAttempt.last
      expect(attempt.workflow_id).to eq(workflow.id)
      expect(attempt.run_id).to eq(agent_run.id)
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

      it "defers a ProcessPrunedError reap while the Run heartbeat is fresh" do
        run = running_run(heartbeat_age: 30.seconds)
        stub_pruned(run.id)
        described_class.perform_now
        expect(run.reload.state).to eq("running")
        expect(run.agent_outcome).to be_nil
      end

      it "defers a ProcessPrunedError reap while the Run has fresh logs" do
        run = running_run(heartbeat_age: ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds)
        JobLog.append!(run: run, chunk: "agent is still making progress")
        stub_pruned(run.id)

        described_class.perform_now

        expect(run.reload.state).to eq("running")
        expect(run.agent_outcome).to be_nil
      end

      it "defers a ProcessPrunedError reap while a spawned process is still running" do
        run = running_run(heartbeat_age: ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds)
        SpawnedProcess.create!(
          run: run,
          kind: "agent",
          command: "claude --print",
          hostname: "worker-1",
          started_at: 5.minutes.ago
        )
        stub_pruned(run.id)

        described_class.perform_now

        expect(run.reload.state).to eq("running")
        expect(run.agent_outcome).to be_nil
      end

      it "reaps a ProcessPrunedError Run once there is no fresh activity or active spawned process" do
        run = running_run(heartbeat_age: ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds)
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

      it "still falls through to heartbeat-stale reaping after deferring fresh SQ-pruned work" do
        sq_pruned = running_run(heartbeat_age: 30.seconds)
        old = running_run(heartbeat_age: Run::STALE_HEARTBEAT_THRESHOLD + 1.minute)
        stub_pruned(sq_pruned.id)
        described_class.perform_now
        expect(sq_pruned.reload.state).to eq("running") # fresh activity defers the SQ signal
        expect(old.reload.state).to eq("failed")        # via heartbeat-stale
      end

      it "reaps a running inline Run when the owning root RunJob was pruned" do
        _workflow, root_run, inline_run = inline_workflow_runs
        stub_pruned_roots(root_run.id)

        described_class.perform_now

        expect(inline_run.reload.state).to eq("failed")
        expect(inline_run.agent_outcome).to eq("worker_died")
      end

      it "defers a pruned inline Run while it is still heartbeating" do
        _workflow, root_run, inline_run = inline_workflow_runs
        inline_run.update_column(:last_heartbeat_at, 30.seconds.ago)
        stub_pruned_roots(root_run.id)

        described_class.perform_now

        expect(inline_run.reload.state).to eq("running")
      end

      it "schedules step resume for a reaped agentic inline Run with a captured session" do
        _workflow, root_run, inline_run = inline_workflow_runs
        ClaudeSession.create!(
          resumable: inline_run,
          provider: inline_run.agent_provider,
          session_id: "agent-thread",
          transcript_jsonl: "{}\n"
        )
        stub_pruned_roots(root_run.id)

        expect {
          described_class.perform_now
        }.to change { AutoRetryAttempt.where(retry_kind: "resume_failed_step").count }.by(1)

        attempt = AutoRetryAttempt.last
        expect(attempt.run_id).to eq(inline_run.id)
        expect(attempt.workflow_id).to eq(inline_run.workflow_id)
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

      it "schedules failed-step retry for a reaped deterministic inline Run" do
        workflow = Workflow.create!(job: job, trigger_kind: "initial")
        step = Step.create!(workflow: workflow, kind: "prepare", position: 0)
        age = ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds
        run = step.runs.create!(job: job, trigger_kind: "initial")
        run.update_columns(
          state: "running",
          started_at: age.ago,
          last_heartbeat_at: age.ago
        )
        stub_active_run_ids

        expect {
          described_class.perform_now
        }.to change { AutoRetryAttempt.where(retry_kind: "failed_step").count }.by(1)

        expect(AutoRetryAttempt.last.run_id).to eq(run.id)
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

    describe "queued-orphan path: Run :queued never enqueued (inline-drive successor)" do
      before { ActiveJob::Base.queue_adapter.enqueued_jobs.clear }

      # SolidQueue tables aren't loaded in the test DB, so stub the
      # root-run lookup. active_run_job_root_run_ids is the only method
      # that hits SolidQueue::Job; workflow_ids_with_active_run_jobs
      # builds on it.
      def stub_active_root_run_ids(*ids)
        allow_any_instance_of(described_class)
          .to receive(:active_run_job_root_run_ids)
          .and_return(ids.map(&:to_i))
      end

      # A :queued Run, older than the grace window, on a :running
      # Workflow — the shape left behind when a worker dies between
      # StepDispatcher creating the next Step's Run and the inline loop
      # running it. The successor Step is still queued in that normal
      # inline-orphan case; a separate spec covers the narrower
      # Step-started/Run-not-started crash window.
      def queued_orphan(step_state: "queued")
        workflow = Workflow.create!(job: job, trigger_kind: "auto_merge")
        workflow.update_columns(state: "running", started_at: 20.minutes.ago)
        step = Step.create!(workflow: workflow, kind: "grader", position: 0)
        step.update_columns(state: step_state)
        run = step.runs.create!(job: job, trigger_kind: "auto_merge")
        run.update_columns(
          state: "queued",
          started_at: nil,
          created_at: (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 1.minute).ago
        )
        [ workflow, step, run ]
      end

      it "re-enqueues a queued orphan when no active RunJob drives its Workflow" do
        _workflow, _step, run = queued_orphan
        stub_active_root_run_ids  # nothing driving anything
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear

        expect { described_class.perform_now }
          .to change { enqueued_run_job_count(run) }.by(1)

        expect(run.reload.state).to eq("queued")  # resumed, not failed
      end

      it "leaves the queued orphan alone when an active RunJob owns its Workflow" do
        _workflow, step, run = queued_orphan
        # A sibling Run on the same Workflow is named by a live SQ::Job
        # (the inline driver still owns the chain).
        root_run = step.runs.create!(job: job, trigger_kind: "auto_merge")
        stub_active_root_run_ids(root_run.id)
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear

        expect { described_class.perform_now }
          .not_to change { enqueued_run_job_count(run) }
      end

      it "re-enqueues a queued Run whose Step already started even if an old root RunJob appears active" do
        _workflow, step, run = queued_orphan(step_state: "running")
        root_run = step.runs.create!(job: job, trigger_kind: "auto_merge")
        stub_active_root_run_ids(root_run.id)
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear

        expect { described_class.perform_now }
          .to change { enqueued_run_job_count(run) }.by(1)

        expect(run.reload.state).to eq("queued")
      end

      it "does not treat a failed root RunJob as an active inline driver" do
        ensure_solid_queue_test_tables!
        clear_solid_queue_test_tables!

        _workflow, step, run = queued_orphan
        root_run = step.runs.create!(job: job, trigger_kind: "auto_merge")
        queue_job = SolidQueue::Job.create!(
          class_name: "RunJob",
          queue_name: "runs",
          priority: 10,
          arguments: { "arguments" => [ root_run.id ] },
          created_at: 10.minutes.ago,
          updated_at: 10.minutes.ago
        )
        SolidQueue::FailedExecution.create!(
          job: queue_job,
          error: { "exception_class" => "SolidQueue::Processes::ProcessPrunedError" },
          created_at: 5.minutes.ago
        )
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear

        expect { described_class.perform_now }
          .to change { enqueued_run_job_count(run) }.by(1)
      ensure
        clear_solid_queue_test_tables! if ActiveRecord::Base.connection.table_exists?(:solid_queue_jobs)
      end

      it "leaves a just-created queued Run alone (inside the grace window)" do
        workflow = Workflow.create!(job: job, trigger_kind: "auto_merge")
        workflow.update_columns(state: "running", started_at: 20.minutes.ago)
        step = Step.create!(workflow: workflow, kind: "grader", position: 0)
        step.update_columns(state: "running")
        run = step.runs.create!(job: job, trigger_kind: "auto_merge")
        run.update_columns(state: "queued", started_at: nil)  # created_at = now
        stub_active_root_run_ids
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear

        expect { described_class.perform_now }
          .not_to change { enqueued_run_job_count(run) }
      end

      it "re-enqueues an old first Run on a still-queued Workflow" do
        workflow = Workflow.create!(job: job, trigger_kind: "initial")
        workflow.update_columns(
          state: "queued",
          created_at: (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 1.minute).ago
        )
        step = Step.create!(workflow: workflow, kind: "prepare", position: 0)
        run = step.runs.create!(job: job, trigger_kind: "initial")
        run.update_columns(
          state: "queued",
          started_at: nil,
          created_at: (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 1.minute).ago
        )
        stub_active_root_run_ids
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear

        expect { described_class.perform_now }
          .to change { enqueued_run_job_count(run) }.by(1)

        expect(workflow.reload).to be_queued
        expect(run.reload).to be_queued
      end

      it "leaves a queued Run alone when its Workflow is terminal" do
        _workflow, _step, run = queued_orphan
        run.step.workflow.update_columns(state: "succeeded", finished_at: 1.minute.ago)
        stub_active_root_run_ids
        ActiveJob::Base.queue_adapter.enqueued_jobs.clear

        expect { described_class.perform_now }
          .not_to change { enqueued_run_job_count(run) }
      end
    end

    describe "queued-workflow path: Workflow :queued but first Run was never created" do
      before { ActiveJob::Base.queue_adapter.enqueued_jobs.clear }

      def queued_workflow_without_runs(job_state: "queued", age: ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds)
        orphan_job = Factories.job_record(state: job_state)
        workflow = Workflows::Initial.instantiate(job: orphan_job)
        workflow.update_columns(created_at: age.ago, updated_at: age.ago)
        workflow.steps.update_all(created_at: age.ago, updated_at: age.ago)
        [ orphan_job, workflow, workflow.first_step ]
      end

      it "starts an old queued workflow whose first Run was never created" do
        _orphan_job, workflow, first_step = queued_workflow_without_runs

        expect(first_step.runs.count).to eq(0)

        expect { described_class.perform_now }
          .to change { first_step.runs.reload.count }.by(1)

        expect(workflow.reload).to be_queued
        expect(first_step.runs.last).to be_queued
      end

      it "leaves a fresh queued workflow alone inside the grace window" do
        _orphan_job, _workflow, first_step = queued_workflow_without_runs(age: 30.seconds)

        expect { described_class.perform_now }
          .not_to change { first_step.runs.reload.count }
      end

      it "does not restart a queued workflow for a closed Job" do
        _orphan_job, _workflow, first_step = queued_workflow_without_runs(job_state: "closed")

        expect { described_class.perform_now }
          .not_to change { first_step.runs.reload.count }
      end

      it "does not bypass unsatisfied dependency gates" do
        repository = Factories.repository
        upstream = Factories.job_record(user: repository.user, repository: repository, issue_number: 41, state: "queued")
        blocked = Factories.job_record(user: repository.user, repository: repository, issue_number: 42, state: "queued")
        JobDependency.create!(job: blocked, depends_on_job: upstream, source: "manual")
        workflow = Workflows::Initial.instantiate(job: blocked)
        workflow.update_columns(
          created_at: (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds).ago,
          updated_at: (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds).ago
        )
        first_step = workflow.first_step

        expect { described_class.perform_now }
          .not_to change { first_step.runs.reload.count }
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

      it "fails a running workflow whose hard-stop failed step is followed by a queued tail" do
        workflow = Workflow.create!(job: job, trigger_kind: "merge_train")
        workflow.update_columns(
          state: "running",
          started_at: (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds).ago
        )
        assemble = Step.create!(workflow: workflow, kind: "merge_train_assemble", position: 0)
        build = Step.create!(workflow: workflow, kind: "merge_train_build", position: 1)
        prepare = Step.create!(workflow: workflow, kind: "prepare", position: 2)
        assemble.update!(next_step_id: build.id)
        build.update!(next_step_id: prepare.id)

        assemble_run = assemble.runs.create!(job: job, trigger_kind: "merge_train")
        assemble.update_columns(state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
        assemble_run.update_columns(state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)

        build_run = build.runs.create!(job: job, trigger_kind: "merge_train")
        build.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
        build_run.update_columns(
          state: "failed",
          agent_outcome: "worker_died",
          started_at: 5.minutes.ago,
          finished_at: 4.minutes.ago
        )

        described_class.perform_now

        expect(workflow.reload).to be_failed
        expect(workflow.failure_reason).to eq("worker_died during merge_train_build")
        expect(workflow.artifact("failure_reason")).to eq("worker_died during merge_train_build")
        expect(prepare.reload).to be_queued
        transition = StateTransition.for_subject(workflow).where(to_state: "failed").last
        expect(transition.source).to eq("reconciler")
      end

      it "does not hard-fail continuable grader failures with queued downstream work" do
        workflow = Workflow.create!(job: job, trigger_kind: "initial")
        workflow.update_columns(
          state: "running",
          started_at: (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds).ago
        )
        grader = Step.create!(workflow: workflow, kind: "grader", position: 0)
        collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 1)
        grader.update!(next_step_id: collect.id)

        run = grader.runs.create!(job: job, trigger_kind: "initial")
        grader.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
        run.update_columns(state: "failed", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)

        described_class.perform_now

        expect(workflow.reload).to be_running
        expect(collect.reload).to be_queued
      end

      it "cancels queued steps whose only runs were cancelled before starting and finishes the workflow" do
        workflow = Workflow.create!(job: job, trigger_kind: "initial")
        workflow.update_columns(
          state: "running",
          started_at: (ReapStaleRunsJob::ORPHAN_RUN_GRACE_PERIOD + 30.seconds).ago
        )
        summarize = Step.create!(workflow: workflow, kind: "summarize", position: 0)
        pr_open = Step.create!(workflow: workflow, kind: "pr_open", position: 1)
        summarize.update!(next_step_id: pr_open.id)

        summarize_run = summarize.runs.create!(job: job, trigger_kind: "initial")
        summarize.update_columns(state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)
        summarize_run.update_columns(state: "succeeded", started_at: 5.minutes.ago, finished_at: 4.minutes.ago)

        pr_open_run = pr_open.runs.create!(job: job, trigger_kind: "initial")
        pr_open_run.update_columns(state: "cancelled", started_at: nil, finished_at: 4.minutes.ago)
        pr_open.update_columns(state: "queued", started_at: nil, finished_at: nil)

        described_class.perform_now

        expect(pr_open.reload).to be_cancelled
        expect(workflow.reload).to be_succeeded
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

  describe "partial JSONL rescue on reap" do
    def running_agentic_run(live_session_id:)
      workflow = Workflow.create!(job: job, trigger_kind: "initial")
      step = Step.create!(workflow: workflow, kind: "implement", position: 0)
      age = Run::STALE_HEARTBEAT_THRESHOLD + 5.minutes
      run = step.runs.create!(job: job, trigger_kind: "initial")
      run.update_columns(
        state: "running",
        started_at: age.ago,
        last_heartbeat_at: age.ago,
        live_session_id: live_session_id
      )
      [ workflow, step, run ]
    end

    around do |example|
      Dir.mktmpdir do |home|
        saved = ENV["HOME"]
        ENV["HOME"] = home
        example.run
      ensure
        ENV["HOME"] = saved
      end
    end

    it "creates a ClaudeSession from JSONL on disk when live_session_id is set and file exists" do
      workflow, _step, run = running_agentic_run(live_session_id: "partial-abc123")
      path = ClaudeSession.canonical_path_for(
        home: ENV["HOME"],
        cwd: WorkflowWorkspace.path_for(workflow).to_s,
        session_id: "partial-abc123"
      )
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{\"type\":\"assistant\"}\n")

      described_class.perform_now

      session = run.reload.claude_session
      expect(session).not_to be_nil
      expect(session.session_id).to eq("partial-abc123")
      expect(session.provider).to eq("claude")
      expect(session.transcript_jsonl).to include("assistant")
    end

    it "does not create a ClaudeSession when the JSONL file does not exist" do
      _workflow, _step, run = running_agentic_run(live_session_id: "missing-session")

      expect { described_class.perform_now }.not_to change { ClaudeSession.count }

      expect(run.reload.claude_session).to be_nil
    end

    it "does not create a ClaudeSession when live_session_id is blank" do
      _workflow, _step, run = running_agentic_run(live_session_id: nil)

      expect { described_class.perform_now }.not_to change { ClaudeSession.count }
    end

    it "skips rescue and does not duplicate when a ClaudeSession already exists" do
      workflow, _step, run = running_agentic_run(live_session_id: "already-captured")
      ClaudeSession.create!(
        resumable: run,
        provider: "claude",
        session_id: "already-captured",
        transcript_jsonl: "{\"type\":\"old\"}\n"
      )
      path = ClaudeSession.canonical_path_for(
        home: ENV["HOME"],
        cwd: WorkflowWorkspace.path_for(workflow).to_s,
        session_id: "already-captured"
      )
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{\"type\":\"new\"}\n")

      expect { described_class.perform_now }.not_to change { ClaudeSession.count }

      expect(run.reload.claude_session.transcript_jsonl).not_to include("new")
    end

    it "enables resume_failed_step scheduling when partial session is rescued from disk" do
      workflow, _step, run = running_agentic_run(live_session_id: "resume-session-xyz")
      path = ClaudeSession.canonical_path_for(
        home: ENV["HOME"],
        cwd: WorkflowWorkspace.path_for(workflow).to_s,
        session_id: "resume-session-xyz"
      )
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "{\"type\":\"system\"}\n")

      expect {
        described_class.perform_now
      }.to change { AutoRetryAttempt.where(retry_kind: "resume_failed_step").count }.by(1)

      attempt = AutoRetryAttempt.last
      expect(attempt.run_id).to eq(run.id)
    end

    it "falls back to failed_step retry when no JSONL is on disk" do
      _workflow, _step, run = running_agentic_run(live_session_id: "no-file-session")

      expect {
        described_class.perform_now
      }.to change { AutoRetryAttempt.where(retry_kind: "failed_step").count }.by(1)

      expect(run.reload.claude_session).to be_nil
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
