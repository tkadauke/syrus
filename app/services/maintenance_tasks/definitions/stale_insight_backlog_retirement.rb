module MaintenanceTasks
  module Definitions
    class StaleInsightBacklogRetirement < Base
      key "stale_insight_backlog_retirement"
      title "Retire stale insight backlog"
      summary "Retires legacy insight suggestions that only exist to mark another insight as superseded."
      category "cleanup"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "stale_insight_backlog_retirement"
      batch_size 250
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/stale_insight_backlog_retirement.md")

      step "retire", "Retire stale insight cards", "Uses the Agent Insights audited retire path for legacy revise-existing and superseded informational cards."

      def estimate_total_units
        service_class&.default_scope&.count.to_i
      end

      def pending_reason
        "#{estimate_total_units} stale insight suggestion(s) can be retired."
      end

      def perform_batch(task)
        return Result.new(done: true, processed: 0, failed: 0, message: "Agent Insights is not installed.", level: "info") unless service_class

        task.current_step_key = "retire"
        task.current_step_title = "Retire stale insight cards"

        result = service_class.new.call
        message = "Checked #{result.checked} stale insight suggestion(s); retired #{result.retired}, skipped #{result.skipped}."
        message += " #{result.errors} insight(s) failed retirement." if result.errors.to_i.positive?

        Result.new(
          done: true,
          processed: result.checked.to_i,
          failed: result.errors.to_i,
          message: message,
          level: result.errors.to_i.positive? ? "warning" : "info"
        )
      end

      private

      def service_class
        @service_class ||= "AgentInsights::StaleBacklogRetirement".safe_constantize
      end
    end
  end
end
