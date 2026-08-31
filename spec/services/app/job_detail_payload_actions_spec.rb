require "rails_helper"
require "tmpdir"
require "fileutils"

RSpec.describe App::JobDetailPayload, :ci_only do
  let(:user) { Factories.user }
  let(:repo) { Factories.repository(user: user) }

  def payload_for(job)
    described_class.build(job: job, user: user)
  end

  def workflows_payload_for(job)
    described_class.workflows(job: job, user: user)
  end

  def capture_sql
    queries = []
    callback = lambda do |_name, _started, _finished, _id, payload|
      next if payload[:cached] || payload[:name] == "SCHEMA"

      queries << payload[:sql]
    end

    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  def attach_work_unit(workflow, member_jobs:, kind: workflow.trigger_kind, state: "running", blocked_reason: nil)
    primary = member_jobs.first
    intent = WorkIntent.create!(
      kind: kind,
      state: "requested",
      repository: primary.repository,
      scope_type: primary.epic_id.present? ? "epic" : "job",
      scope_id: primary.epic_id.presence || primary.id,
      actor: primary.user,
      source_type: "spec"
    )
    unit = WorkUnit.create!(
      work_intent: intent,
      kind: kind,
      state: state,
      repository: primary.repository,
      scope_type: intent.scope_type,
      scope_id: intent.scope_id,
      workflow: workflow,
      blocked_reason: blocked_reason,
      blocked_details: blocked_reason ? { "source" => "spec" } : {}
    )
    member_jobs.each_with_index do |job, index|
      unit.work_unit_members.create!(job: job, role: index.zero? ? "primary" : "member")
    end
    unit
  end
  describe "#feedback_history_json" do
    it "returns chat feedback workflow artifacts in chronological order" do
      job = Factories.job_record(repository: repo)
      newer = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "running",
        created_at: 1.hour.ago,
        artifacts: { "chat_feedback" => "New feedback" }
      )
      older = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "succeeded",
        created_at: 2.hours.ago,
        artifacts: { "chat_feedback" => "Old feedback" }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        state: "succeeded",
        created_at: 3.hours.ago,
        artifacts: { "chat_feedback" => "PR feedback artifact" }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "failed",
        created_at: 30.minutes.ago,
        artifacts: { "chat_feedback" => "" }
      )

      expect(payload_for(job)[:feedback_history]).to eq(
        [
          {
            kind: "chat_feedback",
            body: "Old feedback",
            created_at: older.created_at.iso8601,
            state: "succeeded",
            feedback_source: nil,
            workflow_id: older.id,
            workflow_slug: older.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{older.id}"
          },
          {
            kind: "chat_feedback",
            body: "New feedback",
            created_at: newer.created_at.iso8601,
            state: "running",
            feedback_source: nil,
            workflow_id: newer.id,
            workflow_slug: newer.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{newer.id}"
          }
        ]
      )
    end

    it "returns PR comment workflow artifacts with author attribution" do
      job = Factories.job_record(repository: repo)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        created_at: 1.hour.ago,
        artifacts: {
          "pr_comments" => [
            { "author" => "alice", "body" => "Please cover the blank state." },
            { "author" => "bob", "body" => "This should mention review feedback." }
          ]
        }
      )

      expect(payload_for(job)[:feedback_history]).to eq(
        [
          {
            kind: "pr_comment",
            body: "@alice: Please cover the blank state.\n\n@bob: This should mention review feedback.",
            created_at: workflow.created_at.iso8601,
            state: "succeeded",
            feedback_source: nil,
            workflow_id: workflow.id,
            workflow_slug: workflow.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{workflow.id}"
          }
        ]
      )
    end

    it "excludes PR comment workflows without comments" do
      job = Factories.job_record(repository: repo)
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        artifacts: { "pr_comments" => [] }
      )
      Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "succeeded",
        artifacts: {}
      )

      expect(payload_for(job)[:feedback_history]).to eq([])
    end

    it "interleaves chat feedback and PR comments chronologically" do
      job = Factories.job_record(repository: repo)
      chat_workflow = Workflow.create!(
        job: job,
        trigger_kind: "chat_feedback",
        state: "succeeded",
        created_at: 2.hours.ago,
        artifacts: { "chat_feedback" => "Chat feedback" }
      )
      pr_workflow = Workflow.create!(
        job: job,
        trigger_kind: "pr_comment",
        state: "running",
        created_at: 1.hour.ago,
        artifacts: { "pr_comments" => [ { "author" => "reviewer", "body" => "PR feedback" } ] }
      )

      expect(payload_for(job)[:feedback_history]).to eq(
        [
          {
            kind: "chat_feedback",
            body: "Chat feedback",
            created_at: chat_workflow.created_at.iso8601,
            state: "succeeded",
            feedback_source: nil,
            workflow_id: chat_workflow.id,
            workflow_slug: chat_workflow.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{chat_workflow.id}"
          },
          {
            kind: "pr_comment",
            body: "@reviewer: PR feedback",
            created_at: pr_workflow.created_at.iso8601,
            state: "running",
            feedback_source: nil,
            workflow_id: pr_workflow.id,
            workflow_slug: pr_workflow.slug,
            workflow_path: "/jobs/#{job.id}?tab=workflows#workflow-#{pr_workflow.id}"
          }
        ]
      )
    end

    it "excludes non feedback workflow trigger kinds" do
      job = Factories.job_record(repository: repo)
      %w[initial retry ci_failure].each do |trigger_kind|
        Workflow.create!(
          job: job,
          trigger_kind: trigger_kind,
          state: "succeeded",
          artifacts: {
            "chat_feedback" => "#{trigger_kind} chat feedback",
            "pr_comments" => [ { "author" => "reviewer", "body" => "#{trigger_kind} PR feedback" } ]
          }
        )
      end

      expect(payload_for(job)[:feedback_history]).to eq([])
    end
  end

  describe "#job_json main_branch_repair" do
    it "is false for a regular direct job" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil, issue_title: "Add a feature")

      expect(payload_for(job).dig(:job, :main_branch_repair)).to be(false)
    end

    it "is true for a direct job with the main branch repair title" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil,
                                 issue_title: Job::MAIN_BRANCH_REPAIR_TITLE)

      expect(payload_for(job).dig(:job, :main_branch_repair)).to be(true)
    end

    it "is true for a job with system_kind main_branch_repair" do
      job = Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "direct",
        system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
        issue_title: "Fix broken main branch"
      )

      expect(payload_for(job).dig(:job, :main_branch_repair)).to be(true)
    end

    it "is false for a regular issue job" do
      job = Factories.job_record(user: user, repository: repo, issue_number: 42)

      expect(payload_for(job).dig(:job, :main_branch_repair)).to be(false)
    end
  end

  describe "#actions_json can_retry_pr_ingestion" do
    def external_pr_job(state: "implemented")
      Job.create!(
        user: user, repository: repo,
        kind: "external_pr", state: "implemented",
        external_pr_number: 55, external_pr_fork: false,
        branch_name: "dependabot/bundler/sqlite3-2.9.4"
      ).tap { |j| j.update_columns(state: state) }
    end

    it "is true when the latest external_pr_ingest workflow failed" do
      job = external_pr_job(state: "failed")
      Workflow.create!(job: job, trigger_kind: "external_pr_ingest", state: "failed")

      payload = payload_for(job)

      expect(payload.dig(:actions, :can_retry_pr_ingestion)).to be(true)
      expect(payload.dig(:paths, :app_retry_pr_ingestion_path)).to eq("/api/v1/app/jobs/#{job.id}/retry_pr_ingestion")
    end

    it "is false when the latest external_pr_ingest workflow succeeded" do
      job = external_pr_job
      Workflow.create!(job: job, trigger_kind: "external_pr_ingest", state: "succeeded")

      expect(payload_for(job).dig(:actions, :can_retry_pr_ingestion)).to be(false)
    end

    it "is false for a same-repo issue Job even when its latest workflow failed" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      Workflow.create!(job: job, trigger_kind: "initial", state: "failed")

      expect(payload_for(job).dig(:actions, :can_retry_pr_ingestion)).to be(false)
    end

    it "is false while a workflow is already active for the Job" do
      job = external_pr_job(state: "failed")
      Workflow.create!(job: job, trigger_kind: "external_pr_ingest", state: "failed")
      WorkUnits::Launcher.instantiate(kind: "rebase", job: job).tap do |workflow|
        workflow.update!(state: "running")
        workflow.work_unit.update!(state: "running")
      end

      expect(payload_for(job).dig(:actions, :can_retry_pr_ingestion)).to be(false)
    end
  end

  describe "#actions_json can_restart" do
    def create_failed_workflow(job, trigger_kind:, failed_step_kind:)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: trigger_kind,
        agent_provider: job.agent_provider,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      workflow.steps.create!(
        kind: failed_step_kind,
        position: 1,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      workflow
    end

    it "is false for a queued issue job with no active runs (not yet a last resort)" do
      job = Factories.job_record(repository: repo, issue_number: 5)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for a cron job even with no active runs" do
      scheduled_task = ScheduledTask.create!(
        user: user,
        repository: repo,
        name: "Nightly check",
        cron_expression: "0 3 * * *",
        prompt: "Check the repo.",
        kind: "cron",
        pr_pileup_policy: "skip"
      )
      job = Factories.job_record(user: user, repository: repo, kind: "cron", issue_number: nil,
                                 scheduled_task: scheduled_task)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for a direct job with no active runs (not yet a last resort)" do
      job = Factories.job_record(user: user, repository: repo, kind: "direct", issue_number: nil,
                                 issue_title: "Fix it")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for a no_change_needed job" do
      job = Factories.job_record(user: user, repository: repo, state: "no_change_needed")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is true for a failed job with a non-retryable failed step and a reclaimed workspace" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow = create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "pr_open")
      workflow.update_columns(cleaned_up_at: Time.current)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(true)
    end

    it "is false for a failed job with an available implementation retry" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "implement")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for a failed job with an available failed-step retry" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "pr_open")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for a failed landing attempt with a landing_failure_reason even when no retry action is available" do
      job = Factories.job_record(user: user, repository: repo, state: "failed",
                                 landing_failure_reason: "merge train record not found")
      workflow = create_failed_workflow(job, trigger_kind: "merge_train", failed_step_kind: "merge_train_build")
      workflow.update_columns(cleaned_up_at: Time.current)

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is false for an in-progress landing failure where Reapprove/Retry-failed-step still applies" do
      job = Factories.job_record(user: user, repository: repo, state: "implemented",
                                 landing_failure_reason: "auto_merge: required grader failed")
      create_failed_workflow(job, trigger_kind: "auto_merge", failed_step_kind: "auto_merge")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end

    it "is true for a closed infrastructure (main_grader) job" do
      infra_job = Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "main_grader",
        issue_title: "main_grader:abc123"
      )
      Workflow.create!(job: infra_job, trigger_kind: "main_grader", user: user, state: "succeeded")
      infra_job.update_columns(state: "closed", finished_at: Time.current, closure_reason: "pr_merged")

      expect(payload_for(infra_job).dig(:actions, :can_restart)).to be(true)
    end

    it "is false for a closed non-infrastructure job (Reopen is available instead)" do
      job = Factories.job_record(user: user, repository: repo, state: "closed", closure_reason: "pr_merged")

      expect(payload_for(job).dig(:actions, :can_restart)).to be(false)
    end
  end

  describe "#actions_json for no_change_needed state" do
    def create_no_change_workflow(job)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: "initial",
        agent_provider: job.agent_provider,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      step = workflow.steps.create!(
        kind: "implement",
        position: 1,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      run = Run.create!(job: job, step: step, trigger_kind: "initial", state: "failed")
      run.create_run_diagnostic!(error_class: "Steps::Base::NoChangesProduced", error_message: "agent produced no changes")
      workflow
    end

    it "suppresses retry_implementation_action for no_change_needed jobs" do
      job = Factories.job_record(user: user, repository: repo, state: "no_change_needed")
      create_no_change_workflow(job)

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(false)
      expect(actions[:retry_implementation_action]).to be_nil
    end

    it "suppresses retry_failed_step_action for no_change_needed jobs" do
      job = Factories.job_record(user: user, repository: repo, state: "no_change_needed")
      create_no_change_workflow(job)

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry_from_failed_step]).to be(false)
      expect(actions[:retry_failed_step_action]).to be_nil
    end

    it "allows closing a no_change_needed job" do
      job = Factories.job_record(user: user, repository: repo, state: "no_change_needed")

      expect(payload_for(job).dig(:actions, :can_cancel)).to be(true)
    end
  end

  describe "#actions_json retry actions" do
    def create_failed_workflow(job, trigger_kind:, failed_step_kind:)
      workflow = Workflow.create!(
        job: job,
        trigger_kind: trigger_kind,
        agent_provider: job.agent_provider,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      workflow.steps.create!(
        kind: failed_step_kind,
        position: 1,
        state: "failed",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )
      workflow
    end

    it "offers failed-step retry and implementation retry for implementation-shaped failures" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow = create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "implement")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(true)
      expect(actions[:retry_implementation_action]).to include(
        key: "retry_implementation",
        label: "Retry implementation",
        path: "/api/v1/app/jobs/#{job.id}/run_again"
      )
      expect(actions[:can_retry_from_failed_step]).to be(true)
      expect(actions[:retry_failed_step_action]).to include(
        key: "retry_failed_step",
        label: "Retry failed step",
        workflow_id: workflow.id,
        step_kind: "implement"
      )
    end

    it "does not offer implementation retry for post-implementation workflow failures" do
      job = Factories.job_record(user: user, repository: repo, state: "failed")
      workflow = create_failed_workflow(job, trigger_kind: "initial", failed_step_kind: "pr_open")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(false)
      expect(actions[:retry_implementation_action]).to be_nil
      expect(actions[:retry_failed_step_action]).to include(
        label: "Retry failed step",
        workflow_id: workflow.id,
        step_kind: "pr_open"
      )
    end

    it "offers implementation retry for a reopened cancelled initial workflow" do
      job = Factories.job_record(
        user: user,
        repository: repo,
        state: "triaging",
        closure_reason: nil,
        finished_at: nil
      )
      Workflow.create!(
        job: job,
        trigger_kind: "initial",
        agent_provider: job.agent_provider,
        state: "cancelled",
        started_at: 2.minutes.ago,
        finished_at: 1.minute.ago
      )

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(true)
      expect(actions[:retry_implementation_action]).to include(
        key: "retry_implementation",
        label: "Retry implementation",
        path: "/api/v1/app/jobs/#{job.id}/run_again"
      )
      expect(actions[:can_retry_from_failed_step]).to be(false)
      expect(actions[:retry_failed_step_action]).to be_nil
    end

    it "labels landing workflow retries separately from implementation retries" do
      job = Factories.job_record(
        user: user,
        repository: repo,
        state: "implemented",
        landing_failure_reason: "auto_merge: required grader failed"
      )
      workflow = create_failed_workflow(job, trigger_kind: "auto_merge", failed_step_kind: "auto_merge")

      actions = payload_for(job).fetch(:actions)

      expect(actions[:can_retry]).to be(false)
      expect(actions[:retry_implementation_action]).to be_nil
      expect(actions[:retry_failed_step_action]).to include(
        label: "Retry landing step",
        workflow_id: workflow.id,
        step_kind: "auto_merge"
      )
    end

    it "suppresses all retry actions for infrastructure (main_grader) workflows" do
      infra_job = Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "main_grader",
        issue_title: "main_grader:abc123"
      )
      create_failed_workflow(infra_job, trigger_kind: "main_grader", failed_step_kind: "grader")
      infra_job.update_columns(state: "closed", finished_at: Time.current, closure_reason: "pr_merged")

      actions = payload_for(infra_job).fetch(:actions)

      expect(actions[:can_retry]).to be(false)
      expect(actions[:can_retry_from_failed_step]).to be(false)
      expect(actions[:retry_implementation_action]).to be_nil
      expect(actions[:retry_failed_step_action]).to be_nil
    end
  end

  describe "#actions_json can_reopen" do
    it "is true for a closed non-infrastructure job" do
      job = Factories.job_record(
        user: user,
        repository: repo,
        state: "closed",
        closure_reason: "pr_merged"
      )

      expect(payload_for(job).dig(:actions, :can_reopen)).to be(true)
    end

    it "is false for a closed infrastructure (main_grader) job" do
      infra_job = Job.create!(
        user: user,
        owner_user: user,
        repository: repo,
        kind: "main_grader",
        issue_title: "main_grader:abc123"
      )
      Workflow.create!(job: infra_job, trigger_kind: "main_grader", user: user, state: "succeeded")
      infra_job.update_columns(state: "closed", finished_at: Time.current, closure_reason: "pr_merged")

      expect(payload_for(infra_job).dig(:actions, :can_reopen)).to be(false)
    end

    it "is false for an open job" do
      job = Factories.job_record(user: user, repository: repo, state: "running")

      expect(payload_for(job).dig(:actions, :can_reopen)).to be(false)
    end
  end

  describe "#landing_queue_entry blocker jobs" do
    let(:blocker_repo) { Factories.repository(user: user) }

    it "includes repository, latest workflow fields, and timestamps for each blocker job" do
      blocker_job = Factories.job_record(user: user, repository: blocker_repo, state: "implemented", issue_number: 10, issue_title: "Unfinished prerequisite")
      workflow = Workflow.create!(job: blocker_job, trigger_kind: "initial", state: "running", started_at: 1.hour.ago)

      approved_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      approved_job.approve!(via: "github_review")

      JobDependency.create!(job: approved_job, depends_on_job: blocker_job, source: "manual", created_by_user: user)
      LandingQueueProcessor.refresh_snapshot!(user.jobs)
      approved_job.reload

      entry = payload_for(approved_job)[:landing_queue_entry]
      blocker = entry[:blocker_jobs].find { |b| b[:id] == blocker_job.id }

      expect(blocker).to include(
        id: blocker_job.id,
        repository: hash_including(id: blocker_repo.id, slug: blocker_repo.slug),
        latest_workflow_id: workflow.id,
        latest_workflow_state: "running",
        latest_workflow_trigger_kind: "initial",
        created_at: blocker_job.created_at.iso8601
      )
    end

    it "exposes nil latest_workflow_id for a blocker job with no workflows" do
      blocker_job = Factories.job_record(user: user, repository: blocker_repo, state: "queued", issue_number: 11)

      approved_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      approved_job.approve!(via: "github_review")

      JobDependency.create!(job: approved_job, depends_on_job: blocker_job, source: "manual", created_by_user: user)
      LandingQueueProcessor.refresh_snapshot!(user.jobs)
      approved_job.reload

      entry = payload_for(approved_job)[:landing_queue_entry]
      blocker = entry[:blocker_jobs].find { |b| b[:id] == blocker_job.id }

      expect(blocker[:latest_workflow_id]).to be_nil
    end

    it "omits the queue position for blocked landing queue entries" do
      blocker_job = Factories.job_record(user: user, repository: blocker_repo, state: "implemented", issue_number: 10)
      approved_job = Factories.job_record(user: user, repository: repo, state: "implemented")
      approved_job.approve!(via: "github_review")

      JobDependency.create!(job: approved_job, depends_on_job: blocker_job, source: "manual", created_by_user: user)
      LandingQueueProcessor.refresh_snapshot!(user.jobs)

      expect(payload_for(approved_job.reload).dig(:landing_queue_entry, :position)).to be_nil
    end
  end

  describe "start_blocked_reason" do
    it "returns nil when the job has no queued workflow with a block reason" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")

      expect(payload_for(job).dig(:job, :start_blocked_reason)).to be_nil
      expect(payload_for(job).dig(:job, :start_blocked_at)).to be_nil
      expect(payload_for(job).dig(:job, :start_blocked_details)).to be_nil
    end

    def blocked_workflow_for(job:, reason:, details:, state: "queued", blocked_until: nil)
      workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
      workflow.update!(state: state)
      workflow.work_unit.block!(
        reason: reason,
        blocked_until: blocked_until,
        details: details
      )
      workflow
    end

    it "returns the block reason from the queued workflow's WorkUnit state" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "stack_fan_in_base_unavailable",
        details: {
          "kind" => "fan_in_base_unavailable",
          "message" => "multiple dependency branches are ready",
          "dependencies" => [ { "slug" => "JOB-1574" } ]
        }
      )

      result = payload_for(job)
      expect(result.dig(:job, :start_blocked_reason)).to eq("stack_fan_in_base_unavailable")
      expect(result.dig(:job, :start_blocked_at)).to be_present
      expect(result.dig(:job, :start_blocked_details)).to include(
        "kind" => "fan_in_base_unavailable",
        "message" => "multiple dependency branches are ready",
        "dependencies" => [ { "slug" => "JOB-1574" } ]
      )
    end

    it "returns the block reason from a running workflow deferred at a phase boundary" do
      job = Factories.job_record(user: user, repository: repo, state: "running")
      blocked_workflow_for(
        job: job,
        state: "running",
        reason: "admission_control",
        details: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "action" => "delay_until",
          "reason" => "worker_host_pressure_high",
          "phase_step_kind" => "grader_fanout"
        }
      )

      result = payload_for(job)
      expect(result.dig(:job, :start_blocked_reason)).to eq("workflow_admission_budget")
      expect(result.dig(:job, :start_blocked_at)).to be_present
      expect(result.dig(:job, :start_blocked_details)).to include(
        "reason" => "worker_host_pressure_high",
        "phase_step_kind" => "grader_fanout"
      )
    end

    it "does not compute a breakdown for non-admission block reasons" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "stack_dependencies_not_ready",
        details: { "start_blocked_reason" => "stack_dependencies_not_ready" }
      )

      expect(payload_for(job).dig(:job, :start_blocked_breakdown)).to be_nil
    end

    it "surfaces a step-profile pressure breakdown with current values vs the recorded thresholds" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "admission_control",
        details: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "action" => "delay_until",
          "reason" => "predicted_budget_pressure_high",
          "pressure" => {
            "projected" => { "cpu_pressure" => 132.4, "io_pressure" => 20.0, "memory_used_percent" => 40.0 },
            "host" => { "telemetry_state" => "present" }
          }
        }
      )

      breakdown = payload_for(job).dig(:job, :start_blocked_breakdown)
      expect(breakdown).to include(
        "reason" => "predicted_budget_pressure_high",
        "category" => "step_profile_pressure",
        "telemetry_state" => "present",
        "telemetry_absent" => false
      )
      expect(breakdown["dimensions"]).to include(
        include("metric" => "cpu_pressure", "current" => 132.4, "threshold" => WorkflowAdmissionBudget::CPU_BUDGET, "over_threshold" => true)
      )
    end

    it "surfaces a hard host pressure breakdown for the exact metric that tripped" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "admission_control",
        details: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "action" => "requires_override",
          "reason" => "worker_memory_exhausted",
          "pressure" => { "host" => { "max_memory_used_percent" => 97.2, "telemetry_state" => "present" } }
        }
      )

      breakdown = payload_for(job).dig(:job, :start_blocked_breakdown)
      expect(breakdown["category"]).to eq("hard_host_pressure")
      expect(breakdown["dimensions"]).to eq(
        [ { "metric" => "memory_used_percent", "label" => "Memory used", "current" => 97.2, "threshold" => WorkflowAdmissionBudget::HARD_MEMORY_USED_PERCENT, "over_threshold" => true } ]
      )
    end

    it "distinguishes the telemetry-absent case in the breakdown" do
      job = Factories.job_record(user: user, repository: repo, state: "queued")
      blocked_workflow_for(
        job: job,
        state: "queued",
        reason: "admission_control",
        details: {
          "start_blocked_reason" => StepDispatcher::ADMISSION_BLOCK_REASON,
          "action" => "delay_until",
          "reason" => "worker_host_pressure_high",
          "pressure" => { "host" => { "telemetry_state" => "absent" } }
        }
      )

      breakdown = payload_for(job).dig(:job, :start_blocked_breakdown)
      expect(breakdown["telemetry_state"]).to eq("absent")
      expect(breakdown["telemetry_absent"]).to be(true)
    end
  end

end
