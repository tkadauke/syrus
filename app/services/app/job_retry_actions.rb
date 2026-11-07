module App
  class JobRetryActions
    def self.for(job)
      new(job).as_json
    end

    def initialize(job)
      @job = job
    end

    def as_json
      {
        failed_step: failed_step_action,
        implementation: implementation_action
      }
    end

    private

    attr_reader :job

    def latest_workflow
      @latest_workflow ||= job.latest_workflow
    end

    def failed_step
      @failed_step ||= RetryFailedStepEnqueuer.failed_step_for(latest_workflow) if latest_workflow&.failed?
    end

    def failed_step_action
      return if job.no_change_needed?
      return if latest_workflow&.infrastructure_workflow?
      return unless latest_workflow&.retry_available?
      return unless failed_step
      return if RetryFailedStepEnqueuer.fresh_workflow_required_for?(failed_step)
      return if merge_train_dispatch_blocked?

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

    def implementation_action
      return unless implementation_preflight.eligible?

      {
        key: "retry_implementation",
        label: "Retry implementation",
        path: "/api/v1/app/jobs/#{job.id}/retry_implementation"
      }
    end

    def implementation_preflight
      @implementation_preflight ||= RetryJobs::Modes::Implementation.new(job: job).preflight
    end

    def failed_step_label
      return "Restart grade loop" if failed_step&.kind == "grader_fanout" && failed_step.loop_id.present?
      return "Retry merge train now" if latest_workflow&.trigger_kind == "merge_train"

      Workflow::TriggerKind.retry_label_for(latest_workflow.trigger_kind, step_kind: failed_step&.kind)
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
