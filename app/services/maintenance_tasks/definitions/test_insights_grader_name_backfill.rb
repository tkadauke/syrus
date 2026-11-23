module MaintenanceTasks
  module Definitions
    class TestInsightsGraderNameBackfill < Base
      key "test_insights_grader_name_backfill"
      title "Backfill Test Insights grader names"
      summary "Copies grader names onto historical test cases in bounded, checkpointed batches so named-grader runtime summaries can avoid joining test runs."
      category "backfill"
      recurrence "one_off"
      required_role "admin"
      concurrency_key "test_insights_grader_name_backfill"
      batch_size 1_000
      max_parallelism 1
      documentation_path Rails.root.join("app/services/maintenance_tasks/docs/test_insights_grader_name_backfill.md")

      step "backfill", "Backfill grader names", "Walks historical test cases by primary key and copies each owning test run's grader name."

      AFTER_ID_KEY = "after_id".freeze
      UPPER_BOUND_ID_KEY = "upper_bound_test_case_id".freeze

      def estimate_total_units
        return 0 unless service_class

        service_class.pending_count(after_id: checkpoint_after_id, up_to_id: checkpoint_upper_bound_id || current_upper_bound_id).to_i
      end

      def pending_reason = "#{estimate_total_units} historical test case(s) still need grader names."

      def build_task_attributes(trigger_kind:, trigger_key:, task_key:, requested_by: nil)
        super.tap { |attributes| attributes[:checkpoint][UPPER_BOUND_ID_KEY] = checkpoint_upper_bound_id || current_upper_bound_id }
      end

      def revival_checkpoint(task)
        checkpoint = task.checkpoint.to_h
        after_id = checkpoint[AFTER_ID_KEY].to_i
        upper_bound_id = checkpoint[UPPER_BOUND_ID_KEY].to_i
        upper_bound_id = current_upper_bound_id if upper_bound_id <= 0

        {}.tap do |revived|
          revived[AFTER_ID_KEY] = after_id if after_id.positive?
          revived[UPPER_BOUND_ID_KEY] = upper_bound_id if upper_bound_id.positive?
        end
      end

      def perform_batch(task)
        return Result.new(done: true, processed: 0, failed: 0, message: "Test Insights is not installed.", level: "info") unless service_class

        task.current_step_key = "backfill"
        task.current_step_title = "Backfill grader names"
        after_id = task.checkpoint.fetch(AFTER_ID_KEY, checkpoint_after_id).to_i
        upper_bound_id = task.checkpoint.fetch(UPPER_BOUND_ID_KEY, checkpoint_upper_bound_id || current_upper_bound_id).to_i
        result = service_class.new.call(after_id: after_id, up_to_id: upper_bound_id, limit: task.batch_size)
        task.checkpoint_will_change!
        task.checkpoint[AFTER_ID_KEY] = result.next_after_id
        task.checkpoint[UPPER_BOUND_ID_KEY] = upper_bound_id
        message = result.done ? "Test case grader-name backfill is complete." : "Backfilled #{result.processed} test case(s)."
        Result.new(done: result.done, processed: result.processed, failed: 0, message: message, level: "progress")
      end

      private

      def service_class = "TestInsights::GraderNameBackfill".safe_constantize

      def checkpoint_after_id
        checkpoints.filter_map { |checkpoint| checkpoint[AFTER_ID_KEY].to_i.presence }.max.to_i
      end

      def checkpoint_upper_bound_id
        checkpoints.filter_map { |checkpoint| checkpoint[UPPER_BOUND_ID_KEY].to_i.presence }.max
      end

      def checkpoints
        return [] unless defined?(::MaintenanceTask)

        ::MaintenanceTask.where(definition_key: key, recurrence: recurrence).pluck(:checkpoint).map(&:to_h)
      end

      def current_upper_bound_id = service_class&.max_test_case_id.to_i
    end
  end
end
