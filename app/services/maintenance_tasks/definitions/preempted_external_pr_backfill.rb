module MaintenanceTasks
  module Definitions
    class PreemptedExternalPrBackfill < Base
      key "preempted_external_pr_backfill"
      title "Recover preempted external PR jobs"
      summary "Reopens historical preempted external-PR jobs whose upstream pull request is still open and unmerged."
      category "repair"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "preempted_external_pr_backfill"
      batch_size 100
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/preempted_external_pr_backfill.md")

      step "github_check", "Check external pull requests", "Reads each tracked external pull request and reopens the matching Syrus job only when the PR is still open."

      def estimate_total_units
        Jobs::PreemptedExternalPrBackfill.default_scope.count
      end

      def pending_reason
        "#{estimate_total_units} preempted external PR job(s) need a one-time status check."
      end

      def perform_batch(task)
        task.current_step_key = "github_check"
        task.current_step_title = "Check external pull requests"

        result = Jobs::PreemptedExternalPrBackfill.new.call
        message = "Checked #{result.checked} external PR job(s); reopened #{result.reopened}, skipped #{result.skipped}."
        message += " #{result.errors} GitHub lookup(s) failed." if result.errors.to_i.positive?

        Result.new(
          done: true,
          processed: result.checked.to_i,
          failed: result.errors.to_i,
          message: message,
          level: result.errors.to_i.positive? ? "warning" : "info"
        )
      end
    end
  end
end
