class ReconcileJobStatesJob < ApplicationJob
  queue_as :control_plane

  # States the reconciler will TRY to fix. Referenced by WorkEngine::Reconciler.
  RECONCILABLE_STATES = %w[ queued running implemented failed ].freeze

  def perform
    WorkEngine::Reconciler.request(source: self.class.name)
    Rails.logger.info("[ReconcileJobStatesJob] delegated to unified work-engine reconciler")
  end

  # Called by WorkEngine::Reconciler#classify_completed_infrastructure_jobs.
  def terminal_workflow?(workflow)
    workflow && %w[ succeeded failed cancelled ].include?(workflow.state)
  end

  # Detection + transition plan for one Job. Returns nil when the
  # Job is already consistent with its latest workflow.
  # Used by WorkEngine::Reconciler, WorkEngine::RepairExecutor, and Admin::StuckJobExplainer.
  class Plan
    attr_reader :job, :target_state, :from_state, :reason

    def self.for(job)
      latest_wf = job.latest_workflow
      return nil unless latest_wf
      return nil if job.runaway_protection.present? && !failed_landing_start_blocker_with_ready_pr?(job, latest_wf)

      case [ job.state, latest_wf.state ]
      when [ "failed", "succeeded" ]
        return nil if latest_workflow_missing_pr_publication?(job, latest_wf)

        # Workflow recovered (e.g. via Retry-from-failed-step or
        # follow-up workflow), but Job.state was left at :failed
        # because propagate_succeed_to_job was called when the Job
        # was not :running and the old code returned early.
        new(job, target_state: "implemented",
                  reason: "latest workflow :succeeded but Job stuck at :failed",
                  steps: %i[ retry_after_failure! mark_implemented! ])

      when [ "failed", "running" ]
        # Operator reopened the workflow (or a polling-instantiated
        # follow-up workflow started) but propagate_reopen / propagate_start
        # couldn't lift the Job from :failed. Keep it queued to match
        # retry-from-failed-step's operator-visible state.
        new(job, target_state: "queued",
                  reason: "latest workflow :running but Job stuck at :failed",
                  steps: %i[ retry_after_failure! ])

      when [ "failed", "queued" ]
        # A newer retry/follow-up workflow was created after an older
        # repair workflow failed, but the older terminal callback left
        # the Job at :failed. Return it to :queued so the visible Job
        # state matches the actionable workflow waiting to run.
        new(job, target_state: "queued",
                  reason: "latest workflow :queued but Job stuck at :failed",
                  steps: %i[ retry_after_failure! ])

      when [ "failed", "cancelled" ]
        # Latest attempt was cancelled (operator stop, or chain
        # cascade). Lifting to :queued lets the operator decide
        # what's next instead of leaving a stale :failed pill that
        # implies the failure is current.
        new(job, target_state: "queued",
                  reason: "latest workflow :cancelled but Job stuck at :failed",
                  steps: %i[ retry_after_failure! ])

      when [ "failed", "failed" ]
        if failed_landing_start_blocker_with_ready_pr?(job, latest_wf)
          return new(job, target_state: "approved",
                    reason: "latest workflow :failed only because landing start was blocked, but approved ready PR publication remains valid",
                    steps: %i[ restore_approved_after_landing_start_blocker! ])
        end

        # A branch-diverged pr_open failure can be repaired by adopting or
        # discarding in favor of the current PR branch. If that recovery is
        # already recorded on the latest failed workflow, the PR is the source
        # of truth and the Job should be actionable for approval again.
        return nil unless recovered_branch_divergence_ready_pr?(job, latest_wf)
        return nil if job.any_active_run?
        return nil if job.workflows.where(state: %w[ queued running ]).exists?

        new(job, target_state: "implemented",
                  reason: "latest workflow :failed but recovered branch divergence shows Job has a ready PR",
                  steps: %i[ retry_after_failure! mark_implemented! ])

      when [ "implemented", "running" ]
        # Workflow restarted (reopened) after a successful run, but
        # Job didn't follow into :running. This happens when
        # workflow.reopen fires on a :succeeded → :failed → :running
        # cycle and Job had already advanced to :implemented from
        # the original success.
        new(job, target_state: "running",
                  reason: "latest workflow :running but Job stuck at :implemented",
                  steps: %i[ start_running! ])

      when [ "running", "succeeded" ]
        if latest_workflow_missing_pr_publication?(job, latest_wf)
          return new(job, target_state: "failed",
                    reason: "latest workflow :succeeded without publishing a tracked PR",
                    steps: %i[ mark_failed! ])
        end

        # Workflow finished but propagate_succeed_to_job didn't lift
        # the Job to :implemented (e.g. the catch-all's
        # may_mark_implemented? guard raced with another transition).
        # Only act if the Job genuinely has no active work — don't
        # interfere with a brand-new workflow that just started.
        return nil if job.any_active_run?
        return nil if job.workflows.where(state: %w[ queued running ]).exists?

        new(job, target_state: "implemented",
                  reason: "latest workflow :succeeded but Job stuck at :running",
                  steps: %i[ mark_implemented! ])

      when [ "running", "failed" ]
        # Workflow failed but propagate_fail_to_job didn't fire (e.g.
        # the after-callback was skipped because the workflow row
        # was written through update_columns or a raw SQL update).
        # Only act if the Job has no other active work.
        return nil if job.any_active_run?
        return nil if job.workflows.where(state: %w[ queued running ]).exists?

        new(job, target_state: "failed",
                  reason: "latest workflow :failed but Job stuck at :running",
                  steps: %i[ mark_failed! ])

      when [ "running", "cancelled" ]
        # Workflow was cancelled (operator stop, deploy interruption,
        # or workflow cascade), but the Job missed the terminal
        # propagation and still looks active. With no active work left,
        # surface it as failed so the normal Retry / Start-over actions
        # are available instead of leaving it in the dashboard's running
        # set forever.
        return nil if job.any_active_run?
        return nil if job.workflows.where(state: %w[ queued running ]).exists?

        new(job, target_state: "failed",
                  reason: "latest workflow :cancelled but Job stuck at :running",
                  steps: %i[ mark_failed! ])

      when [ "queued", "succeeded" ]
        return nil if latest_workflow_missing_pr_publication?(job, latest_wf)

        # Should rarely happen — implies an old workflow finished
        # but the Job got bounced back to :queued without a new
        # workflow being instantiated. Treat the workflow's success
        # as the source of truth.
        return nil if job.workflows.where(state: %w[ queued running ]).exists?

        new(job, target_state: "implemented",
                  reason: "latest workflow :succeeded but Job stuck at :queued",
                  steps: %i[ start_running! mark_implemented! ])

      when [ "queued", "running" ]
        # Workflow#start normally transitions queued Jobs to running.
        # If that callback is interrupted or bypassed, the Job remains
        # invisible as actively progressing even though its latest
        # workflow owns live work.
        new(job, target_state: "running",
                  reason: "latest workflow :running but Job stuck at :queued",
                  steps: %i[ start_running! ])

      when [ "queued", "cancelled" ]
        # A stale auto-retry can be cancelled after a previous retry
        # already published a current, passing PR. In that shape the
        # latest Workflow is no longer the source of truth; the ready
        # PR plus earlier successful publication is.
        return nil unless ready_pr_with_successful_publication?(job, latest_wf)
        return nil if job.any_active_run?
        return nil if job.workflows.where(state: %w[ queued running ]).exists?

        new(job, target_state: "implemented",
                  reason: "latest workflow :cancelled but ready PR publication shows Job should be :implemented",
                  steps: %i[ start_running! mark_implemented! ])
      end
    end

    def self.ready_pr_with_successful_publication?(job, latest_wf)
      return false unless job.pr_number.present?
      return false unless job.branch_name.present?
      return false unless job.commits_behind_base.to_i.zero?
      return false unless job.github_mergeable_state == "clean"
      return true if workflow_published_ready_pr?(job, latest_wf)
      return false unless job.pr_checks_state == "passing"

      successful_publication_for_branch?(job, latest_wf)
    end

    def self.latest_workflow_missing_pr_publication?(job, latest_wf)
      return false unless latest_wf
      return false unless latest_wf.steps.where(kind: "pr_open").exists?
      return false if latest_wf.steps.where(kind: "pr_open", state: "succeeded").exists?
      return false if job.pr_number.present? || job.external_pr_number.present? || job.fork_review_pr_number.present?
      return false if job.infrastructure_job?
      return false if latest_wf.trigger_kind == "main_branch_repair" && latest_wf.artifact("preflight_passed")

      true
    end

    def self.failed_landing_start_blocker_with_ready_pr?(job, latest_wf)
      return false unless latest_wf&.failed?
      return false unless latest_wf.landing_workflow?
      return false unless LandingQueueReentry.landing_start_blocker?(latest_wf.failure_reason.presence || latest_wf.artifact("failure_reason") || WorkUnits::StartBlock.for(latest_wf).reason)
      return false unless LandingQueueReentry.landing_start_blocker?(job.landing_failure_reason)
      return false unless job.approved_at.present?
      return false unless job.pr_number.present?
      return false unless job.branch_name.present?
      return false unless job.commits_behind_base.to_i.zero?
      return false unless job.github_mergeable_state == "clean"
      return true if job.pr_checks_state == "passing"

      successful_publication_for_branch?(job, latest_wf)
    end

    def self.workflow_published_ready_pr?(job, workflow)
      return false unless workflow

      publication_branch = workflow.artifact("publication_branch").presence
      return true if publication_branch == job.branch_name

      workflow.steps.where(kind: "pr_open", state: "succeeded").exists?
    end

    def self.successful_publication_for_branch?(job, latest_wf)
      branch_name = job.branch_name.presence
      return false unless branch_name

      job.workflows
         .where(state: "succeeded")
         .where("id < ?", latest_wf.id)
         .any? do |workflow|
           workflow.artifact("publication_branch").presence == branch_name
         end
    end

    def self.recovered_branch_divergence_ready_pr?(job, latest_wf)
      return false unless job.pr_number.present?
      return false unless job.branch_name.present?
      return false unless latest_wf&.failed?
      return false unless latest_wf.artifact("branch_divergence_recovery").is_a?(Hash)
      return false unless latest_wf.artifact("branch_divergence_recovery")["action"].in?(%w[
        superseded_by_current_pr_branch
        adopted_current_pr_head
      ])

      divergence = latest_wf.artifact("branch_divergence")
      return false unless divergence.is_a?(Hash)

      remote_sha = divergence["remote_sha"].presence
      return false if remote_sha.blank?

      current_head = job.mergeability_head_sha.presence || job.pr_checks_sha.presence
      current_head == remote_sha
    end

    def initialize(job, target_state:, reason:, steps:)
      @job = job
      @from_state = job.state
      @target_state = target_state
      @reason = reason
      @steps = steps
    end

    def apply!
      job.with_lock do
        job.reload
        # Re-check: the world may have moved between detection and
        # the lock. If the Job is no longer in the from_state we
        # observed, the plan is stale.
        return if job.state != @from_state

        StateTransition.with_source(
          "reconciler",
          reason: "reconcile_job_state",
          metadata: {
            "repair_action" => "reconcile_job_state",
            "repair_reason" => reason,
            "target_state" => target_state,
            "from_state" => from_state
          }
        ) do
          @steps.each do |event|
            guard = "may_#{event.to_s.chomp('!')}?"
            break unless job.public_send(guard)

            job.public_send(event)
            job.save!
          end
        end
      end
    end
  end
end
