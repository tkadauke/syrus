module ScheduledTasks
  # Durable identity for one intended firing of a scheduled task.
  #
  # The unique task/due-at pair is the cross-process idempotency boundary.
  # Fire holds this row's lock while creating the Job and advancing the task,
  # so a transaction rollback leaves the occurrence safely retryable.
  class Occurrence < Syrus::Host::Record
    self.table_name = "scheduled_task_occurrences"

    belongs_to :task, class_name: "ScheduledTasks::Task", foreign_key: :scheduled_task_id,
                      inverse_of: false

    validates :due_at, presence: true, uniqueness: { scope: :scheduled_task_id }

    def job
      Syrus::Host::JobRecord.find_by(id: job_id) if job_id
    end

    def complete!(job:, at: Time.current)
      update!(job_id: job&.id, completed_at: at)
    end
  end
end
