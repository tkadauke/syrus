require "rails_helper"

RSpec.describe WorkEngine::RepairExecutor do
  RepairResult = Data.define(:repair_plans)

  let(:job) { Factories.job }
  let(:workflow) { job.latest_workflow }

  def repair_plan(action:, target:)
    WorkEngine::RepairPlanner::Plan.new(
      issue_kind: "running_workflow_without_active_descendants",
      action: action,
      auto_executable: true,
      target_type: target.class.name,
      target_id: target.id,
      affected_ids: {},
      execution_steps: [],
      preconditions: {},
      reason: "test"
    )
  end

  describe "mark_cached_grader_collect_failed" do
    def queued_grader_collect
      workflow.update_columns(state: "running", started_at: 5.minutes.ago)
      step = workflow.steps.create!(kind: "grader_collect", position: 99, state: "queued")
      step.runs.create!(
        job: job, trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider, state: "queued"
      )
    end

    def mark_failed(run)
      described_class.call(
        result: RepairResult.new([ repair_plan(action: "mark_cached_grader_collect_failed", target: run) ])
      ).sole
    end

    before { allow(GraderConclusionCache).to receive(:failed_for_workflow?).and_return(true) }

    # `run_diagnostics.run_id` is uniquely indexed, and a second pass repairing
    # the same Run raised RecordNotUnique. The raise did not come from the
    # diagnostic write — Rails' find_or_create_by! already falls back to
    # create_or_find_by! — it came from `run.fail!` afterwards. Writing the
    # diagnostic through `run:` assigns the losing candidate into Run's
    # has_one inverse; its savepoint rolls back, the unsaved record stays the
    # association target, and the Run's own save re-attempts the insert. So
    # the repair caused the duplicate it was recording a failure for.
    #
    # Reproducing it needs the row to be missing when this pass looks and
    # present when it inserts, which is two connections, and the suite runs on
    # one. So the row is committed up front and only RunDiagnostic's relation
    # lookup is blinded — the state the losing pass actually sees.
    def blind_run_diagnostic_lookups
      original = ActiveRecord::FinderMethods.instance_method(:find_by)
      allow_any_instance_of(ActiveRecord::Relation).to receive(:find_by) do |relation, *args|
        relation.klass == RunDiagnostic ? nil : original.bind(relation).call(*args)
      end
    end

    it "does not re-insert the diagnostic when failing the Run afterwards" do
      run = queued_grader_collect
      RunDiagnostic.create!(run: run, error_class: "Steps::Base::StepFailed", error_message: "written by the winner")
      blind_run_diagnostic_lookups

      execution = described_class.call(
        result: RepairResult.new([ repair_plan(action: "mark_cached_grader_collect_failed", target: run) ])
      ).sole

      expect(execution.status).to eq("applied")
      expect(RunDiagnostic.where(run: run).count).to eq(1)
      expect(RunDiagnostic.find_by(run: run).error_message).to eq("written by the winner")
      expect(run.reload).to be_failed
    end
  end

  describe "cancel_terminal_workflow_active_descendants" do
    # Production: the repair checked "terminal" and then cancelled, while a
    # Retry-from-failed-step (which reopens the Workflow under the Job lock)
    # revived the same Workflow in between -- the retry's fresh grader Runs
    # were cancelled. The repair must decide under the same lock.
    it "re-reads the Workflow under the Job lock and leaves a just-reopened one alone" do
      workflow.update_columns(state: "failed", finished_at: 1.minute.ago)
      tail = workflow.steps.create!(kind: "grader", position: 99, state: "queued")
      original = Job.instance_method(:with_lock)
      allow_any_instance_of(Job).to receive(:with_lock) do |locked_job, *args, &block|
        # The retry held the lock and committed its reopen just before us.
        workflow.update_columns(state: "running", finished_at: nil)
        original.bind(locked_job).call(*args, &block)
      end

      execution = described_class.call(
        result: RepairResult.new([ repair_plan(action: "cancel_terminal_workflow_active_descendants", target: workflow) ])
      ).sole

      expect(execution.status).to eq("skipped")
      expect(tail.reload).to be_queued
    end
  end

  describe "reconcile_step_from_terminal_run" do
    # A plan made before the failed Run scheduled its in-place retry must not
    # finish the Step that is now waiting for that retry.
    it "skips a Step waiting for a pending in-place retry" do
      workflow.update_columns(state: "running", started_at: 5.minutes.ago)
      step = workflow.steps.create!(kind: "grader", position: 99, state: "running", started_at: 5.minutes.ago)
      run = step.runs.create!(
        job: job, trigger_kind: workflow.trigger_kind,
        agent_provider: workflow.agent_provider, state: "failed", finished_at: 1.minute.ago
      )
      AutoRetryAttempt.create!(
        job: job, workflow: workflow, run: run, agent_provider: "claude",
        failure_classification: "git_transport_transient", retry_kind: "failed_step",
        attempt_number: 1, scheduled_at: 4.minutes.from_now
      )

      execution = described_class.call(
        result: RepairResult.new([ repair_plan(action: "reconcile_step_from_terminal_run", target: step) ])
      ).sole

      expect(execution.status).to eq("skipped")
      expect(execution.message).to eq("Step is waiting for an in-place retry")
      expect(step.reload).to be_running
    end
  end

  describe "recover_missing_workspace" do
    it "keeps a successfully reconstructed workflow active" do
      workflow.update_columns(
        state: "running", started_at: 5.minutes.ago,
        worker_hostname: "retired-worker", worker_storage_key: "retired-storage"
      )
      result = WorkflowWorkspaceRecovery::Result.new(
        status: "recovered", workflow: workflow, run: nil, message: "workspace reconstructed"
      )
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(false)
      allow(WorkflowWorkspaceRecovery).to receive(:call).with(workflow: workflow).and_return(result)

      execution = described_class.call(
        result: RepairResult.new([ repair_plan(action: "recover_missing_workspace", target: workflow) ])
      ).sole

      expect(execution).to have_attributes(status: "applied", message: "workspace reconstructed")
      expect(workflow.reload).to have_attributes(
        state: "running",
        workspace_lifecycle_state: "storage_lost",
        worker_hostname: nil,
        worker_storage_key: nil,
        last_workspace_hostname: "retired-worker",
        last_workspace_storage_key: "retired-storage"
      )
      expect(workflow.workflow_workspace_events.last).to have_attributes(
        event_type: "storage_lost",
        actor: "work_engine_repair",
        reason: "workspace missing from inactive storage owner"
      )
    end

    it "skips recovery when the owning remote worker has heartbeated since the plan was made" do
      workflow.update_columns(state: "running", started_at: 5.minutes.ago, worker_hostname: "mac-worker", worker_storage_key: "storage-mac")
      InstanceVersion.create!(hostname: "mac-worker", role: "worker", version: "x",
                              started_at: 1.hour.ago, last_heartbeat_at: 1.minute.ago)
      allow(WorkerStorageIdentity).to receive(:queue_key).and_return("storage-linux")
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(false)
      expect(WorkflowWorkspaceRecovery).not_to receive(:call)

      execution = described_class.call(
        result: RepairResult.new([ repair_plan(action: "recover_missing_workspace", target: workflow) ])
      ).sole

      expect(execution).to have_attributes(status: "skipped", message: "workspace is held by another worker")
      expect(workflow.reload).to have_attributes(state: "running", worker_storage_key: "storage-mac")
    end

    it "fails an unsafe reconstruction with a typed retryable infrastructure outcome" do
      workflow.update_columns(state: "running", started_at: 5.minutes.ago)
      work_unit = workflow.work_unit
      expect(work_unit).to be_active
      expect(work_unit.work_unit_locks.active).to exist
      result = WorkflowWorkspaceRecovery::Result.new(
        status: "retry_required", workflow: workflow, run: workflow.runs.last,
        message: "durable head validation failed"
      )
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(false)
      allow(WorkflowWorkspaceRecovery).to receive(:call).with(workflow: workflow).and_return(result)

      execution = nil
      expect {
        execution = described_class.call(
          result: RepairResult.new([ repair_plan(action: "recover_missing_workspace", target: workflow) ])
        ).sole
      }.to have_enqueued_job(AutoRetryJob)

      expect(execution).to have_attributes(status: "applied")
      expect(workflow.reload).to be_failed
      expect(workflow.artifact("workspace_recovery_failure")).to include(
        "classification" => "workspace_recovery_failed",
        "retryable" => true,
        "reason" => "durable head validation failed"
      )
      expect(result.run.run_failure_classification.reload).to have_attributes(
        classification: "workspace_recovery_failed",
        retryable: true,
        confidence: 1.0
      )
      expect(workflow.auto_retry_attempts.last).to have_attributes(
        retry_kind: "retry_workflow",
        failure_classification: "workspace_recovery_failed"
      )
      expect(work_unit.reload).to be_failed
      expect(work_unit.work_unit_locks.active).not_to exist
    end

    it "keeps the interrupted step failed and cancels a never-started grade loop and publication tail" do
      workflow.update_columns(state: "running", started_at: 5.minutes.ago)
      causal_run = workflow.runs.last
      causal_step = causal_run.step
      causal_step.update_columns(kind: "visual_review", state: "running", started_at: 4.minutes.ago)
      causal_run.update_columns(state: "running", started_at: 4.minutes.ago)
      grade_fanout = workflow.steps.create!(kind: "grader_fanout", position: causal_step.position + 1, state: "queued", loop_id: "grade-loop")
      grade_collect = workflow.steps.create!(kind: "grader_collect", position: causal_step.position + 2, state: "queued", loop_id: "grade-loop")
      publication = workflow.steps.create!(kind: "summarize", position: causal_step.position + 3, state: "queued")
      causal_step.update!(next_step: grade_fanout)
      grade_fanout.update!(next_step: grade_collect)
      grade_collect.update!(next_step: publication)
      recovery_fails_with("durable head validation failed")

      described_class.call(
        result: RepairResult.new([ repair_plan(action: "recover_missing_workspace", target: workflow) ])
      )

      expect(causal_step.reload).to be_failed
      expect(causal_run.reload).to have_attributes(state: "failed", agent_outcome: "workspace_recovery_failed")
      expect([ grade_fanout.reload, grade_collect.reload, publication.reload ]).to all(be_cancelled)
      expect([ grade_fanout, grade_collect, publication ]).to all(satisfy { |step| step.runs.none? })
      expect(RetryFailedStepEnqueuer.failed_step_for(workflow.reload)).to eq(causal_step)
    end

    # The half-step this spec used to stop before. Scheduling the retry is not
    # the same thing as the retry happening: AutoRetryJob re-derives the
    # failure classification before it will act, and these Runs carry no
    # evidence for a classifier to read, because this repair is what ended
    # them.
    it "keeps its verdict when the classifier re-derives and finds nothing" do
      workflow.update_columns(state: "running", started_at: 5.minutes.ago)
      run = workflow.runs.last
      recovery_fails_with("durable head validation failed")

      described_class.call(
        result: RepairResult.new([ repair_plan(action: "recover_missing_workspace", target: workflow) ])
      )

      # Re-derivation on its own finds nothing and would say so.
      expect(RunFailureClassifier.classify(run.reload)).to have_attributes(
        classification: RunFailureClassifier::UNCLASSIFIED, retryable: false
      )
      # Persisting that must not replace the repair's confident verdict.
      expect(RunFailureClassifier.persist!(run)).to have_attributes(
        classification: "workspace_recovery_failed", retryable: true, confidence: 1.0
      )
    end

    # The regression. These Runs carry no exception and no agent output --
    # the repair is what ended them -- so with nothing declared the classifier
    # fell through to `application_error, retryable: false`, AutoRetryJob
    # skipped the attempt as "failure is not retryable", and the Job stayed
    # failed with failure_count 0 and no second workflow. Seven Jobs died that
    # way in one night.
    it "lets the scheduled retry actually start a fresh workflow" do
      workflow.update_columns(state: "running", started_at: 5.minutes.ago)
      recovery_fails_with("no durable source snapshot, branch head, or agent checkpoint is available")

      described_class.call(
        result: RepairResult.new([ repair_plan(action: "recover_missing_workspace", target: workflow) ])
      )
      attempt = workflow.auto_retry_attempts.last
      expect(attempt).to be_present

      expect { AutoRetryJob.perform_now(attempt.id) }.to change { job.workflows.count }.by(1)

      expect(attempt.reload).to have_attributes(skipped_reason: nil)
      expect(attempt.performed_at).to be_present
    end

    def recovery_fails_with(message)
      result = WorkflowWorkspaceRecovery::Result.new(
        status: "retry_required", workflow: workflow, run: workflow.runs.last, message: message
      )
      allow(File).to receive(:directory?).and_call_original
      allow(File).to receive(:directory?).with(WorkflowWorkspace.path_for(workflow)).and_return(false)
      allow(WorkflowWorkspaceRecovery).to receive(:call).with(workflow: workflow).and_return(result)
      result
    end
  end

  describe "release_urgent_blocked_landing_slot" do
    def urgent_slot_plan(unit)
      repair_plan(action: "release_urgent_blocked_landing_slot", target: unit)
    end

    def urgent_blocked_landing_unit
      repository = job.repository
      landing_job = Factories.job_record(user: job.user, repository: repository, state: "landing", priority: "medium")
      workflow = WorkUnits::Launcher.instantiate(kind: "auto_merge", job: landing_job)
      unit = workflow.work_unit
      landing_key = unit.work_unit_locks.active.find_by!("lock_key LIKE ?", "landing:repository:%").lock_key
      unit.block!(reason: "urgent_job_active")
      unit.work_unit_locks.create!(lock_key: landing_key)
      blocker = Factories.job_record(user: job.user, repository: repository, state: "approved", priority: "urgent")
      [ unit, workflow, blocker ]
    end

    it "is idempotent when the same repair plan is executed twice" do
      unit, = urgent_blocked_landing_unit
      plan = urgent_slot_plan(unit)

      first, second = 2.times.map do
        described_class.call(result: RepairResult.new([ plan ])).sole
      end

      expect(first).to have_attributes(status: "applied")
      expect(second).to have_attributes(status: "skipped", message: "WorkUnit ##{unit.id} holds no repository landing slot")
    end

    it "skips when a Run appears after planning" do
      unit, workflow, = urgent_blocked_landing_unit
      Run.create!(job: workflow.job, step: workflow.first_step, trigger_kind: workflow.trigger_kind, state: "queued")

      result = described_class.call(result: RepairResult.new([ urgent_slot_plan(unit) ])).sole

      expect(result).to have_attributes(status: "skipped", message: "Blocked Workflow is no longer queued landing work before its first Run")
      expect(unit.work_unit_locks.active.where("lock_key LIKE ?", "landing:repository:%")).to exist
    end

    it "skips when the landing slot was already released" do
      unit, = urgent_blocked_landing_unit
      unit.release_landing_locks!

      result = described_class.call(result: RepairResult.new([ urgent_slot_plan(unit) ])).sole

      expect(result).to have_attributes(status: "skipped", message: "WorkUnit ##{unit.id} holds no repository landing slot")
    end

    it "skips when the urgent blocker clears after planning" do
      unit, _, blocker = urgent_blocked_landing_unit
      blocker.update_columns(state: "closed")

      result = described_class.call(result: RepairResult.new([ urgent_slot_plan(unit) ])).sole

      expect(result).to have_attributes(status: "skipped", message: "No unrelated urgent blocker remains active")
      expect(unit.work_unit_locks.active.where("lock_key LIKE ?", "landing:repository:%")).to exist
    end
  end

  it "fails a running workflow with an uncleared retry barrier instead of marking it succeeded" do
    workflow.steps.destroy_all
    loop_id = SecureRandom.uuid
    fanout = Step.create!(workflow: workflow, kind: "grader_fanout", position: 1, loop_id: loop_id, state: "succeeded", finished_at: 5.minutes.ago)
    collect = Step.create!(workflow: workflow, kind: "grader_collect", position: 2, loop_id: loop_id, state: "cancelled", finished_at: 4.minutes.ago)
    fanout.update!(next_step: collect)
    workflow.update_columns(state: "running", started_at: 10.minutes.ago, finished_at: nil)

    result = described_class.call(
      result: RepairResult.new([
        repair_plan(action: "finish_workflow_from_terminal_descendants", target: workflow)
      ])
    )

    expect(result.first).to have_attributes(status: "applied")
    expect(result.first.message).to include("marked #{workflow.slug} failed")
    expect(workflow.reload).to be_failed
  end

  it "uses normal completion guards when terminal descendants appear successful" do
    workflow.steps.update_all(state: "succeeded", finished_at: 4.minutes.ago)
    workflow.steps.find_by!(kind: "pr_open").update_columns(state: "cancelled")
    Step.create!(
      workflow: workflow,
      kind: "summarize",
      position: workflow.steps.maximum(:position) + 1,
      state: "succeeded",
      finished_at: 3.minutes.ago
    )
    workflow.runs.update_all(state: "succeeded", finished_at: 4.minutes.ago)
    workflow.update_columns(state: "running", started_at: 10.minutes.ago, finished_at: nil)

    result = described_class.call(
      result: RepairResult.new([
        repair_plan(action: "finish_workflow_from_terminal_descendants", target: workflow)
      ])
    )

    expect(result.first).to have_attributes(status: "applied")
    expect(workflow.reload).to be_failed
    expect(workflow.failure_reason).to eq("pr_publication_missing_after_success")
  end

  it "requires operator review when the final Step has no success or failure outcome" do
    workflow.steps.update_all(state: "blocked", finished_at: 4.minutes.ago)
    workflow.update_columns(state: "running", started_at: 10.minutes.ago, finished_at: nil)

    issue = WorkEngine::Reconciler::Issue.new(
      kind: "running_workflow_without_active_descendants",
      severity: "error",
      evidence: {},
      affected_ids: { job_ids: [ job.id ], workflow_ids: [ workflow.id ] },
      safe_to_auto_repair: true,
      recommended_repair_action: "finish_workflow_from_terminal_descendants",
      explanation: "test"
    )
    result = WorkEngine::Reconciler::Result.new("spec", Time.current, nil, [ issue ], [], [])

    plan = WorkEngine::RepairPlanner.call(result: result).first

    expect(plan).to have_attributes(
      action: "operator_review_terminal_workflow_outcome",
      auto_executable: false,
      target_type: "Workflow",
      target_id: workflow.id
    )
    expect(workflow.reload).to be_running
  end

  it "cancels an obsolete requested WorkIntent instead of launching it after its Job closes" do
    target = Factories.job_record(user: job.user, repository: job.repository, issue_number: 501)
    intent = WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: target.repository,
      scope_type: "job",
      scope_id: target.id,
      actor: target.user,
      source_type: "spec"
    )
    target.update_columns(state: "closed", finished_at: Time.current, closure_reason: "pr_merged")

    result = described_class.call(
      result: RepairResult.new([
        repair_plan(action: "launch_requested_work_intent", target: intent)
      ])
    )

    expect(result.first).to have_attributes(
      status: "applied",
      message: "cancelled #{intent.slug} because #{target.slug} is closed"
    )
    expect(intent.reload).to be_cancelled
    expect(target.workflows).to be_empty
  end

  it "reports a requested WorkIntent as skipped when launch creates no Run" do
    target = Factories.job_record(user: job.user, repository: job.repository, state: "backlog", issue_number: 502)
    intent = WorkIntent.create!(
      kind: "initial",
      state: "requested",
      repository: target.repository,
      scope_type: "job",
      scope_id: target.id,
      actor: target.user,
      source_type: "spec"
    )

    result = described_class.call(
      result: RepairResult.new([
        repair_plan(action: "launch_requested_work_intent", target: intent)
      ])
    )

    expect(result.first).to have_attributes(
      status: "skipped",
      message: "#{intent.slug} did not start: #{StepDispatcher::BACKLOG_BLOCK_REASON}"
    )
    expect(intent.reload).to be_requested
    expect(target.workflows.last.first_step.runs).to be_empty
  end

  # Regression: a merge train owns its members through `merge_train_members`,
  # but the train's single WorkUnit is instantiated with only the tip job, so
  # every other member has no WorkUnitMember row. `stranded?` asked the
  # WorkUnit question alone and therefore deferred live train members out of
  # `landing` while the train was still grading -- which the land step then
  # rejected as "members not in :landing", throwing away the whole assembly.
  describe "release_externally_blocked_landing_slot with merge train members" do
    def release_plan(unit)
      WorkEngine::RepairPlanner::Plan.new(
        issue_kind: "externally_blocked_landing_slot",
        action: "release_externally_blocked_landing_slot",
        auto_executable: true,
        target_type: unit.class.name,
        target_id: unit.id,
        affected_ids: {},
        execution_steps: [],
        preconditions: { "work_unit_id" => unit.id },
        reason: "test"
      )
    end

    def blocked_landing_unit_for(member_job)
      intent = WorkIntent.create!(
        kind: "job_bundle",
        state: "requested",
        scope_type: "job",
        scope_id: member_job.id,
        repository: member_job.repository,
        actor: member_job.user,
        requested_at: Time.current,
        source_type: "spec"
      )
      unit = WorkUnit.create!(
        work_intent: intent,
        kind: "job_bundle",
        state: "blocked",
        blocked_reason: "no_capable_worker",
        scope_type: "job",
        scope_id: member_job.id,
        repository: member_job.repository
      )
      unit.work_unit_members.create!(job: member_job, role: "primary")
      unit.work_unit_locks.create!(lock_key: "#{WorkUnit::LANDING_LOCK_KEY_PREFIX}repository:#{member_job.repository_id}")
      unit
    end

    let(:member_job) do
      Factories.job_record(user: job.user, repository: job.repository, issue_number: 777).tap do |j|
        j.update_columns(state: "landing", approved_at: Time.current)
      end
    end

    it "leaves a member of an active merge train in landing" do
      unit = blocked_landing_unit_for(member_job)
      train = MergeTrain.create!(repository: job.repository, base_branch: "main", state: "grading", priority: "medium")
      MergeTrainMember.create!(merge_train: train, job: member_job, position: 0)

      described_class.call(
        result: RepairResult.new([
          release_plan(unit)
        ])
      )

      expect(member_job.reload.state).to eq("landing")
    end

    it "still defers a landing Job that no active train owns" do
      unit = blocked_landing_unit_for(member_job)

      described_class.call(
        result: RepairResult.new([
          release_plan(unit)
        ])
      )

      expect(member_job.reload.state).to eq("approved")
    end
  end

  describe "repair_merge_train_member_reconciliation" do
    let(:client) { instance_double(GithubClient, add_issue_comment: true, close_pull_request: true, delete_branch: true) }
    let(:member_job) do
      Factories.job_record(user: job.user, repository: job.repository, issue_number: 778).tap do |j|
        j.update_columns(state: "landing", approved_at: Time.current, pr_number: 4242, branch_name: "syrus/direct-4242")
      end
    end
    let(:train) do
      MergeTrain.create!(
        repository: job.repository, base_branch: "main", state: "succeeded", priority: "medium",
        integration_sha: "trainsha123", finished_at: 1.minute.from_now
      )
    end

    before do
      allow(GithubClient).to receive(:for).and_return(client)
      MergeTrainMember.create!(merge_train: train, job: member_job, position: 0, state: "failed")
      LandedCommit.create!(landable: member_job, sha: "member-landed-1", kind: "implementation", position: 0)
    end

    def reconcile!
      plan = repair_plan(action: "repair_merge_train_member_reconciliation", target: member_job)
      plan = plan.with(preconditions: { "merge_train_id" => train.id })
      described_class.call(result: RepairResult.new([ plan ])).sole
    end

    # A member closed here never passed through the land step's cleanup, so
    # its PR stayed open forever and the open PR kept the stale-branch reaper
    # from ever deleting the branch.
    it "closes the member's PR and deletes its branch, like the land step does" do
      reconcile!

      expect(member_job.reload).to be_closed
      expect(client).to have_received(:add_issue_comment).with(job.repository.slug, 4242, a_string_including("merge-train"))
      expect(client).to have_received(:close_pull_request).with(job.repository.slug, 4242)
      expect(client).to have_received(:delete_branch).with(job.repository.slug, "syrus/direct-4242")
      expect(member_job.branch_deleted_at).to be_present
    end

    it "still closes the member when GitHub cleanup fails" do
      allow(client).to receive(:delete_branch).and_raise(Octokit::ServerError)

      reconcile!

      expect(member_job.reload).to be_closed
      expect(member_job.branch_deleted_at).to be_nil
    end
  end

  describe "resume_queued_step on a CI repair held behind a superseded base" do
    let(:base_sha) { "abc1234567890000000000000000000000000000" }
    let(:ci_workflow) do
      Workflow.create!(
        job: job, trigger_kind: "ci_failure", state: "running", started_at: 2.days.ago, created_at: 2.days.ago,
        artifacts: { "base_sha" => base_sha, "head_sha" => "def1234567890000000000000000000000000000" },
        chain_template: [
          { "type" => "step", "kind" => "prepare" },
          { "type" => "retry_until", "max_iterations" => 3, "repair" => [ "analyze_and_fix" ],
            "check" => [ "grader_fanout", "grader_collect" ], "repair_first" => true }
        ]
      )
    end
    let!(:analyze) do
      Step.create!(workflow: ci_workflow, kind: "prepare", position: 0, state: "succeeded")
      Step.create!(workflow: ci_workflow, kind: "analyze_and_fix", position: 1, state: "queued", loop_id: "loop-1")
    end

    before do
      job.update!(state: "approved", pr_checks_base_sha: base_sha, commits_behind_base: 0)
      job.repository.update!(main_branch_health_enabled: true, last_health_checked_sha: "older")
      intent = WorkIntent.create!(
        kind: "ci_failure", state: "requested", repository: job.repository, scope_type: "job", scope_id: job.id,
        actor: job.user, source_type: "spec", payload_artifacts: ci_workflow.artifacts
      )
      unit = WorkUnit.create!(
        work_intent: intent, kind: "ci_failure", state: "running", repository: job.repository,
        scope_type: "job", scope_id: job.id, workflow: ci_workflow
      )
      unit.work_unit_members.create!(job: job, role: "primary")
      allow(StepDispatcher).to receive(:deferred_phase_handoff_ready?).and_return(true)
      allow(WorkUnits::DeferredPhaseResume).to receive(:call)
        .and_return(Struct.new(:run, :status, :reason).new(nil, "blocked", "ci_repair_safety"))
    end

    def resume!
      described_class.call(result: RepairResult.new([ repair_plan(action: "resume_queued_step", target: analyze) ])).sole
    end

    # A CI repair that ran `prepare` and was then held waiting for its base to
    # be known healthy sat "running" for weeks once main moved on: no health
    # check grades an old base, and the superseded-base cancel only handled
    # repairs still queued.
    it "cancels the repair once main health has moved past its base" do
      MainBranchHealthCheck.create!(
        repository: job.repository, branch: "main", sha: "fff1234567890000000000000000000000000000",
        checked_at: 1.day.ago, source: "ci_poll", ci_health: "healthy", grader_health: "healthy"
      )

      execution = resume!

      expect(execution.status).to eq("applied")
      expect(ci_workflow.reload).to be_cancelled
      expect(ci_workflow.artifact("cancelled_reason")).to eq(WorkUnits::Gates::CiRepairSafety::SUPERSEDED_BASE_REASON)
    end

    # Regression: a CI repair held behind a running main-branch repair kept
    # waiting after main moved four commits past its base -- the superseded
    # base was only checked for the "not known healthy" block, so a stale
    # main repair held an approved Job's landing all afternoon.
    it "cancels a repair held behind a main repair once main has moved past its base" do
      repair_job = job.repository.jobs.create!(
        user: job.user, kind: "direct", system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
        issue_title: "repair", issue_body: "Main branch health is broken.\n\nCommit: #{base_sha}\n", agent_provider: "claude",
        priority: "high", state: "queued"
      )
      Workflow.create!(job: repair_job, trigger_kind: "main_branch_repair", state: "running", started_at: 1.hour.ago)
      MainBranchHealthCheck.create!(
        repository: job.repository, branch: "main", sha: "fff1234567890000000000000000000000000000",
        checked_at: 1.day.ago, source: "ci_poll", ci_health: "broken", grader_health: "broken"
      )
      expect(WorkUnits::Gates::CiRepairSafety.call(ci_workflow.work_unit, step: analyze).details["kind"]).to eq("base_repair_active")

      execution = resume!

      expect(execution.status).to eq("applied")
      expect(ci_workflow.reload).to be_cancelled
    end

    it "keeps waiting while the base can still be graded" do
      execution = resume!

      expect(execution.status).to eq("skipped")
      expect(ci_workflow.reload).to be_running
    end
  end

  # The classifier only reports a member running alongside a running keeper
  # (EpicWorkflowLock::ConflictDetector). The executor re-checked only that
  # both were active, so a plan could still cancel a member that was merely
  # waiting for the Epic-wide Workflow.
  describe "cancel_epic_workflow_conflict" do
    let(:epic) { Factories.epic(user: job.user, repository: job.repository) }
    let(:keeper_job) { Factories.job_record(user: job.user, repository: job.repository, epic: epic, issue_number: 301) }
    let(:member_job) { Factories.job_record(user: job.user, repository: job.repository, epic: epic, issue_number: 302) }
    let(:keeper) { Workflow.create!(job: keeper_job, trigger_kind: "stack_rebase", state: "running") }

    def conflict_plan(member)
      WorkEngine::RepairPlanner::Plan.new(
        issue_kind: "epic_workflow_conflict",
        action: "cancel_epic_workflow_conflict",
        auto_executable: true,
        target_type: "Workflow",
        target_id: member.id,
        affected_ids: {},
        execution_steps: [],
        preconditions: { "keeper_workflow_id" => keeper.id },
        reason: "test"
      )
    end

    it "leaves a member that is only waiting for the Epic-wide workflow" do
      member = Workflow.create!(job: member_job, trigger_kind: "initial", state: "queued")

      execution = described_class.call(result: RepairResult.new([ conflict_plan(member) ])).sole

      expect(execution.status).to eq("skipped")
      expect(member.reload).to be_queued
    end

    it "cancels a member running alongside a running Epic-wide workflow" do
      member = Workflow.create!(job: member_job, trigger_kind: "initial", state: "running")

      execution = described_class.call(result: RepairResult.new([ conflict_plan(member) ])).sole

      expect(execution.status).to eq("applied")
      expect(member.reload).to be_cancelled
    end
  end
  describe "finish_workflow_from_terminal_descendants" do
    it "skips a Workflow whose last Step waits for an in-place retry" do
      step = workflow.steps.order(:position).first
      workflow.steps.where.not(id: step.id).delete_all
      step.update!(kind: "grader", next_step: nil)
      Run.where(step_id: step.id).delete_all
      workflow.update_columns(state: "running", started_at: 10.minutes.ago)
      step.update_columns(state: "running", started_at: 10.minutes.ago)
      run = step.runs.create!(job: job, trigger_kind: workflow.trigger_kind, agent_provider: "claude", state: "failed", finished_at: 1.minute.ago)
      AutoRetryAttempt.create!(
        job: job, workflow: workflow, run: run, agent_provider: "claude",
        failure_classification: "git_transport_transient", retry_kind: "failed_step",
        attempt_number: 1, scheduled_at: 4.minutes.from_now
      )

      execution = described_class.call(
        result: RepairResult.new([ repair_plan(action: "finish_workflow_from_terminal_descendants", target: workflow) ])
      ).sole

      expect(execution).to have_attributes(status: "skipped", message: "A Step is waiting for an in-place retry")
      expect(workflow.reload).to be_running
    end
  end
  describe "satisfy_work_intent_from_succeeded_work_unit" do
    it "skips a succeeded unit that a newer unit of the same intent has outlived" do
      old_unit = workflow.work_unit
      intent = old_unit.work_intent
      old_unit.update_columns(state: "succeeded", finished_at: 2.hours.ago)
      WorkUnit.create!(
        work_intent: intent, kind: old_unit.kind, state: "failed",
        repository: job.repository, scope_type: "job", scope_id: job.id,
        started_at: 1.hour.ago, finished_at: 30.minutes.ago
      )
      intent.update_columns(state: "requested")
      plan = WorkEngine::RepairPlanner::Plan.new(
        issue_kind: "succeeded_work_unit_unsatisfied_intent",
        action: "satisfy_work_intent_from_succeeded_work_unit",
        auto_executable: true,
        target_type: "WorkIntent",
        target_id: intent.id,
        affected_ids: {},
        execution_steps: [],
        preconditions: { "work_unit_id" => old_unit.id },
        reason: "test"
      )

      execution = described_class.call(result: RepairResult.new([ plan ])).sole

      expect(execution.status).to eq("skipped")
      expect(execution.message).to include("is not the latest finished unit")
      expect(intent.reload).to be_requested
    end
  end
end
