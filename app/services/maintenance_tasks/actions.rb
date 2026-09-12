module MaintenanceTasks
  class Actions
    def self.start!(task, user:) = new(task, user: user).start!
    def self.pause!(task, user:) = new(task, user: user).pause!
    def self.resume!(task, user:) = new(task, user: user).resume!
    def self.cancel!(task, user:) = new(task, user: user).cancel!
    def self.dismiss!(task, user:) = new(task, user: user).dismiss!

    def initialize(task, user:)
      @task = task
      @user = user
    end

    def start!
      transition_to_running!("Started")
    end

    def resume!
      transition_to_running!("Resumed")
    end

    def pause!
      @task.with_lock do
        return @task unless @task.state == "running"

        @task.update!(state: "paused", paused_at: Time.current)
        @task.log!("Paused by #{@user.display_name}.")
      end
      @task
    end

    def cancel!
      @task.with_lock do
        return @task if @task.terminal?

        @task.update!(state: "cancelled", cancelled_at: Time.current, finished_at: Time.current)
        @task.log!("Cancelled by #{@user.display_name}.", level: "warning")
      end
      @task
    end

    def dismiss!
      @task.update!(state: "dismissed", dismissed_at: Time.current, dismissed_by_user: @user)
      @task.log!("Dismissed by #{@user.display_name}.")
      @task
    end

    private

    def transition_to_running!(verb)
      @task.with_lock do
        @task.reload
        raise ArgumentError, "maintenance task is not runnable from #{@task.state}" unless @task.runnable? || @task.state == "dismissed"

        total = @task.definition.estimate_total_units
        if total.zero?
          @task.update!(state: "not_needed", total_units: 0, completed_units: 0, eta_seconds: 0, finished_at: Time.current)
          @task.log!("No matching maintenance work remains.")
          return @task
        end

        @task.update!(
          state: "running",
          total_units: total,
          requested_by_user: @user,
          dismissed_at: nil,
          dismissed_by_user: nil,
          started_at: @task.started_at || Time.current,
          paused_at: nil,
          finished_at: nil,
          cancelled_at: nil,
          last_error: nil
        )
        @task.log!("#{verb} by #{@user.display_name}.")
      end

      MaintenanceTaskRunJob.perform_later(@task.id)
      @task
    end
  end
end
