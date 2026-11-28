module App
  class JobRetryActions
    RECOVERY_ACTION_LABELS = {
      "rerun_unchanged" => "Rerun check",
      "resume" => "Resume execution",
      "repair_with_guidance" => "Repair with guidance",
      "fresh_implementation" => "Restart implementation",
      "restart" => "Restart implementation"
    }.freeze

    def self.for(job)
      new(job).as_json
    end

    def initialize(job)
      @job = job
    end

    def as_json
      {
        recovery_decision: RecoveryContract.for_job(job, workflow: latest_workflow)[:decision],
        recovery_timeline: recovery_timeline,
        failed_step: failed_step_action,
        failed_step_blocker: failed_step_blocker&.as_json,
        implementation: implementation_action
      }
    end

    private

    attr_reader :job

    def recovery_decision
      @recovery_decision ||= RecoveryDecision.for(job: job, workflow: latest_workflow)
    end

    def latest_workflow
      @latest_workflow ||= job.latest_workflow
    end

    def recovery_timeline
      job.recovery_interventions.map do |intervention|
        {
          id: intervention.id, action: intervention.action,
          actor: intervention.actor_display.presence || intervention.actor_type,
          actor_type: intervention.actor_type, origin: intervention.origin,
          reason: intervention.reason, guidance: intervention.guidance,
          source_revision: intervention.source_revision, resulting_revision: intervention.resulting_revision,
          performed_at: intervention.performed_at&.iso8601
        }.compact
      end
    end

    def failed_step
      @failed_step ||= RetryFailedStepEnqueuer.failed_step_for(latest_workflow) if latest_workflow&.failed?
    end

    def failed_step_action
      return if job.no_change_needed?
      return if latest_workflow&.infrastructure_workflow?
      return if branch_divergence_resolved?
      return unless latest_workflow&.retry_available?
      return unless failed_step
      return if RetryFailedStepEnqueuer.fresh_workflow_required_for?(failed_step)
      return if merge_train_dispatch_blocked?
      return if failed_step_blocker

      {
        key: "retry_failed_step",
        label: failed_step_label,
        workflow_id: latest_workflow.id,
        step_id: failed_step.id,
        step_kind: failed_step.kind,
        step_label: Step::Kind.label_for(failed_step.kind),
        path: "/api/v1/app/jobs/#{job.id}/workflows/#{latest_workflow.id}/retry_step"
      }
    end

    def failed_step_blocker
      @failed_step_blocker ||= RetryFailedStepEnqueuer.preflight(workflow: latest_workflow) if failed_step
    end

    def implementation_action
      return unless implementation_preflight.eligible?

      {
        key: "retry_implementation",
        label: implementation_action_label,
        path: "/api/v1/app/jobs/#{job.id}/retry_implementation"
      }
    end

    # The operator already settled this workflow's failed publication through
    # branch divergence recovery (replaced, adopted, or discarded). Retrying the
    # step would publish the same choice again, and offering it kept "Retry
    # failed step" as the Job's headline action, ahead of approving the Job
    # the recovery had just made approvable.
    def branch_divergence_resolved?
      latest_workflow&.failed? && latest_workflow.artifact("branch_divergence_recovery").present?
    end

    def implementation_preflight
      @implementation_preflight ||= RetryJobs::Modes::Implementation.new(job: job).preflight
    end

    def failed_step_label
      return recovery_action_label if failed_step&.kind == "grader_fanout" && failed_step.loop_id.present?
      return "Retry merge train now" if latest_workflow&.trigger_kind == "merge_train"

      Workflow::TriggerKind.retry_label_for(latest_workflow.trigger_kind, step_kind: failed_step&.kind)
    end

    def implementation_action_label
      if job.failed? && recovery_decision.recommended_action.in?(%w[fresh_implementation restart])
        return recovery_action_label
      end

      "Retry implementation"
    end

    def recovery_action_label
      RECOVERY_ACTION_LABELS.fetch(recovery_decision.recommended_action, "Retry")
    end

    def merge_train_dispatch_blocked?
      return false unless latest_workflow&.trigger_kind == "merge_train"

      merge_train_dispatcher_blocker_reason.present?
    end

    def merge_train_dispatcher_blocker_reason
      train = merge_train_for_latest_workflow
      return unless train

      if train.bundle_backed?
        JobBundleDispatcher.blocker_reason(train.repository, bypass_cooldown: true)
      else
        MergeTrainDispatcher.blocker_reason(train.epic, bypass_cooldown: true)
      end
    end

    def merge_train_for_latest_workflow
      train_id = latest_workflow&.artifact("merge_train_id")
      return if train_id.blank?

      MergeTrain.find_by(id: train_id)
    end
  end
end
