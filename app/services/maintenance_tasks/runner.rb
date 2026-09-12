module MaintenanceTasks
  class Runner
    TARGET_BATCH_SECONDS = 15.0

    def initialize(task)
      @task = task
      @definition = task.definition
    end

    def call
      return unless @task.state == "running"

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = @definition.perform_batch(@task)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      @task.with_lock do
        @task.reload
        return unless @task.state == "running"

        completed = @task.completed_units.to_i + result.processed.to_i
        failed = @task.failed_units.to_i + result.failed.to_i
        @task.assign_attributes(
          completed_units: completed,
          failed_units: failed,
          current_step_key: @task.current_step_key,
          current_step_title: @task.current_step_title,
          eta_seconds: eta_seconds(completed, @task.total_units, elapsed, result.processed.to_i),
          last_error: nil
        )

        if result.done
          @task.state = "succeeded"
          @task.finished_at = Time.current
          @task.completed_units = @task.total_units if @task.total_units.positive?
          @task.eta_seconds = 0
        end

        @task.save!
        @task.log!(
          result.message.presence || "Processed #{result.processed.to_i} item(s).",
          level: result.level.presence || "progress",
          metadata: { elapsed_seconds: elapsed.round(3) }
        )
      end

      MaintenanceTaskRunJob.perform_later(@task.id) if @task.reload.state == "running"
    rescue StandardError => e
      @task.update!(state: "failed", last_error: "#{e.class}: #{e.message}") if @task.persisted?
      @task.log!("#{e.class}: #{e.message}", level: "error") if @task.persisted?
      raise
    end

    private

    def eta_seconds(completed, total, elapsed, processed)
      return nil if total.to_i <= 0 || completed.to_i <= 0 || processed.to_i <= 0

      rate = processed / elapsed.clamp(0.001, TARGET_BATCH_SECONDS)
      ((total - completed).clamp(0, total) / rate).round
    end
  end
end
