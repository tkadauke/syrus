module Workflows
  class JobLifecyclePropagation
    def self.start!(workflow) = new(workflow).start!
    def self.succeed!(workflow) = new(workflow).succeed!
    def self.fail!(workflow) = new(workflow).fail!
    def self.cancel!(workflow) = new(workflow).cancel!
    def self.reopen!(workflow) = new(workflow).reopen!

    def initialize(workflow)
      @workflow = workflow
    end

    # Landing-flow workflows own their Job state through landing-specific
    # machinery. Lifecycle-owner definitions do the same through workflow
    # hooks. Ordinary workflows drive their parent Job into :running here.
    def start!
      return if workflow.landing_workflow?
      return if workflow.infrastructure_workflow?
      return unless job.may_start_running?

      StateTransition.with_source("propagate") do
        job.start_running!
        job.save!
      end
    end

    # Follow-up workflows whose chains do not publish a PR should return the
    # Job to :implemented. PR-producing workflows that reached success without
    # publishing a PR are failed so the reconciler/operator can see the broken
    # publication path.
    def succeed!
      return if workflow.landing_workflow?
      return if workflow.infrastructure_workflow?
      return if job.implemented? || job.approved? || job.landing? || job.closed?

      StateTransition.with_source("propagate") do
        if job.failed? && job.may_retry_after_failure?
          job.retry_after_failure!
          job.save!
        end

        if pr_publication_missing_after_success?
          if job.may_mark_failed?
            job.mark_failed!
            job.save!
          end
          return
        end

        return unless job.may_mark_implemented?

        job.mark_implemented!
        job.save!
      end
    end

    # When a workflow fails, drive ordinary Jobs into :failed. Specialized
    # workflows either own their own hooks or keep landing/ingest state through
    # dedicated services.
    def fail!
      return if workflow.landing_workflow?
      return if workflow.coding_handoff_workflow?
      return if workflow.local_mode_handoff_workflow?
      return if workflow.external_pr_ingest_workflow?
      return if workflow.infrastructure_workflow?
      return if newer_active_workflow?

      if no_changes_produced_failure?
        return unless job.may_close?

        StateTransition.with_source("propagate") do
          job.close_with_reason!("no_changes")
        end
      else
        return unless job.may_mark_failed?

        StateTransition.with_source("propagate") do
          job.mark_failed!
          job.save!
        end
      end
    end

    def cancel!
      return if workflow.landing_workflow?
      return if workflow.coding_handoff_workflow?
      return if workflow.local_mode_handoff_workflow?
      return if workflow.infrastructure_workflow?
      return if workflow.superseded_cancellation?

      if cancelled_rebase_without_runs_on_triaging_job?
        StateTransition.with_source("propagate") do
          if job.may_restore_after_cancelled_rebase?
            job.restore_after_cancelled_rebase!
            job.save!
          end
        end
        return
      end

      return unless job.running? && job.may_mark_failed?

      StateTransition.with_source("propagate") do
        job.mark_failed!
        job.save!
      end
    end

    # Reopening a failed workflow for "Retry from failed step" resumes the
    # parent Job into active work without creating a new attempt.
    def reopen!
      return if workflow.landing_workflow?

      StateTransition.with_source("propagate") do
        if job.failed? && job.may_retry_after_failure?
          job.retry_after_failure!
          job.save!
        end

        if job.may_start_running?
          job.start_running!
          job.save!
        end
      end
    end

    def pr_publication_missing_after_success?
      publication_step_kinds = workflow.work_definition.review_publication_step_kinds
      return false if publication_step_kinds.empty?
      return false unless workflow.steps.where(kind: publication_step_kinds).exists?
      return false if workflow.steps.where(kind: publication_step_kinds, state: "succeeded").exists?
      return false if job.pr_number.present? || job.external_pr_number.present? || job.fork_review_pr_number.present?
      return false if job.infrastructure_job?
      return false if workflow.trigger_kind == "main_branch_repair" && workflow.artifact("preflight_passed")

      true
    end

    private

    attr_reader :workflow

    def job
      workflow.job
    end

    def newer_active_workflow?
      return false unless workflow.persisted?

      cutoff = workflow.created_at || Time.zone.at(0)
      active_workflow_ids = WorkUnits::Ownership.active_workflow_ids([ job.id ]).to_a - [ workflow.id ]
      return false if active_workflow_ids.empty?

      job.workflows
        .where(id: active_workflow_ids)
        .where("created_at > ? OR (created_at = ? AND id > ?)", cutoff, cutoff, workflow.id)
        .exists?
    end

    def no_changes_produced_failure?
      workflow.runs.where(state: "failed")
        .joins(:run_diagnostic)
        .where(run_diagnostics: { error_class: "Steps::Base::NoChangesProduced" })
        .exists?
    end

    def cancelled_rebase_without_runs_on_triaging_job?
      workflow.trigger_kind.in?(%w[rebase stack_rebase]) &&
        workflow.runs.none? &&
        job.triaging?
    end
  end
end
