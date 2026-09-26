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

      AFTER_ID_KEY = "after_id".freeze
      UPPER_BOUND_ID_KEY = "upper_bound_test_run_id".freeze

      def estimate_total_units
        return 0 unless service_class

        service_class
          .pending_count(after_id: checkpoint_after_id, up_to_id: checkpoint_upper_bound_id || current_upper_bound_id)
          .to_i
      end

      def pending_reason
        "#{estimate_total_units} historical grader-loop test run(s) have not been reclassified yet."
      end

      def build_task_attributes(trigger_kind:, trigger_key:, task_key:, requested_by: nil)
        super.tap do |attributes|
          attributes[:checkpoint][UPPER_BOUND_ID_KEY] = checkpoint_upper_bound_id || current_upper_bound_id
        end
      end

      def revival_checkpoint(task)
        checkpoint = task.checkpoint.to_h
        after_id = checkpoint[AFTER_ID_KEY].to_i
        upper_bound_id = checkpoint[UPPER_BOUND_ID_KEY].to_i
        upper_bound_id = after_id if upper_bound_id <= 0 && task.state == "succeeded"
        upper_bound_id = current_upper_bound_id if upper_bound_id <= 0

        {}.tap do |revived|
          revived[AFTER_ID_KEY] = after_id if after_id.positive?
          revived[UPPER_BOUND_ID_KEY] = upper_bound_id if upper_bound_id.positive?
        end
      end

      def perform_batch(task)
        return Result.new(done: true, processed: 0, failed: 0, message: "Test Insights is not installed.", level: "info") unless service_class

        task.current_step_key = "classify"
        task.current_step_title = "Classify historical grader-loop test runs"

        after_id =
          if task.checkpoint.key?(AFTER_ID_KEY)
            task.checkpoint[AFTER_ID_KEY].to_i
          else
            checkpoint_after_id
          end
        upper_bound_id =
          if task.checkpoint.key?(UPPER_BOUND_ID_KEY)
            task.checkpoint[UPPER_BOUND_ID_KEY].to_i
          else
            checkpoint_upper_bound_id || current_upper_bound_id
          end
        result = service_class.new.call(after_id: after_id, up_to_id: upper_bound_id, limit: task.batch_size)

        task.checkpoint_will_change!
        task.checkpoint[AFTER_ID_KEY] = result.next_after_id
        task.checkpoint[UPPER_BOUND_ID_KEY] = upper_bound_id

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
          .filter_map { |checkpoint| checkpoint.to_h[AFTER_ID_KEY].to_i.presence }
          .max
          .to_i
      end

      def checkpoint_upper_bound_id
        return nil unless defined?(::MaintenanceTask)

        explicit_bound = ::MaintenanceTask
          .where(definition_key: key, recurrence: recurrence)
          .pluck(:checkpoint)
          .filter_map { |checkpoint| checkpoint.to_h[UPPER_BOUND_ID_KEY].to_i.presence }
          .max
        return explicit_bound if explicit_bound.present?

        ::MaintenanceTask
          .where(definition_key: key, recurrence: recurrence, state: "succeeded")
          .pluck(:checkpoint)
          .filter_map { |checkpoint| checkpoint.to_h[AFTER_ID_KEY].to_i.presence }
          .max
      end

      def current_upper_bound_id
        service_class&.max_test_run_id.to_i
      end
    end
  end
end
