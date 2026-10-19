module Workflows
  # Replays a failed workflow's latest durable mutation checkpoint on a newly
  # resolved base. The historical workflow and its source snapshots remain
  # immutable; validation and publication happen in this new attempt.
  class BaseRefreshRetry < Base
    def self.trigger_kind = "base_refresh_retry"

    def self.steps_for(job)
      syrus_yml = resolve_default_branch_syrus_yml(job)
      [
        "base_refresh_rebase",
        "agent_rebase",
        "publish_source_snapshot",
        "prepare",
        grader_retry_loop(job, :implement, autofix: true, repair_first: false, syrus_yml: syrus_yml),
        "coverage_analyze",
        "dependency_audit",
        *initial_pr_finish_steps(job, syrus_yml: syrus_yml)
      ].flatten.compact
    end

    def self.after_success(workflow)
      record_outcome(workflow, "succeeded")
    end

    def self.after_fail(workflow)
      record_outcome(workflow, "failed")
    end

    def self.after_cancel(workflow)
      record_outcome(workflow, "cancelled")
    end

    def self.record_outcome(workflow, outcome)
      workflow.set_artifact!("base_refresh_outcome", {
        "status" => outcome,
        "recorded_at" => Time.current.iso8601
      })
    end
    private_class_method :record_outcome
  end
end
