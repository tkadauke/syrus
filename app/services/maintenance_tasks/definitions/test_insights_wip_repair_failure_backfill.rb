module MaintenanceTasks
  module Definitions
    class TestInsightsWipRepairFailureBackfill < Base
      key "test_insights_wip_repair_failure_backfill"
      title "Backfill WIP-repair-failure flags"
      summary "Replays the WIP-repair-failure classifier over historical grader-loop test runs so pre-existing test_insight_cases rows get the same flag ingestion now sets going forward."
      category "backfill"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "test_insights_wip_repair_failure_backfill"
      batch_size 200
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/test_insights_wip_repair_failure_backfill.md")

      step "classify", "Classify historical grader-loop test runs", "Walks test_insight_runs from grader-retry-loop iterations, oldest first, and replays TestInsights::WipRepairFailureClassifier over each one."

      def estimate_total_units
        service_class&.pending_count(after_id: checkpoint_after_id).to_i
      end

      def pending_reason
        "#{estimate_total_units} historical grader-loop test run(s) have not been reclassified yet."
      end

      def revival_checkpoint(task)
        after_id = task.checkpoint.to_h["after_id"].to_i
        after_id.positive? ? { "after_id" => after_id } : {}
      end

      def perform_batch(task)
        return Result.new(done: true, processed: 0, failed: 0, message: "Test Insights is not installed.", level: "info") unless service_class

        task.current_step_key = "classify"
        task.current_step_title = "Classify historical grader-loop test runs"

        after_id =
          if task.checkpoint.key?("after_id")
            task.checkpoint["after_id"].to_i
          else
            checkpoint_after_id
          end
        result = service_class.new.call(after_id: after_id, limit: task.batch_size)

        task.checkpoint_will_change!
        task.checkpoint["after_id"] = result.next_after_id

        message = result.done ? "WIP-repair-failure backfill is complete." : "Reclassified #{result.processed} test run(s)."

        Result.new(done: result.done, processed: result.processed, failed: 0, message: message, level: "progress")
      end

      private

      def service_class
        @service_class ||= "TestInsights::WipRepairFailureBackfill".safe_constantize
      end

      def checkpoint_after_id
        return 0 unless defined?(::MaintenanceTask)

        ::MaintenanceTask
          .where(definition_key: key, recurrence: recurrence)
          .pluck(:checkpoint)
          .filter_map { |checkpoint| checkpoint.to_h["after_id"].to_i.presence }
          .max
          .to_i
      end
    end
  end
end
