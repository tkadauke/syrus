class RequeueStrandedMailDeliveries < ActiveRecord::Migration[8.1]
  MAIL_DELIVERY_JOB = "ActionMailer::MailDeliveryJob"
  SOURCE_QUEUE = "mailers"
  TARGET_QUEUE = "control_plane"

  def up
    return unless table_exists?(:solid_queue_jobs)

    requeue_executions(:solid_queue_ready_executions)
    requeue_executions(:solid_queue_scheduled_executions)

    execute <<~SQL.squish
      UPDATE solid_queue_jobs
      SET queue_name = #{quote(TARGET_QUEUE)}
      WHERE class_name = #{quote(MAIL_DELIVERY_JOB)}
        AND queue_name = #{quote(SOURCE_QUEUE)}
        AND finished_at IS NULL
    SQL
  end

  def down
    # Delivered jobs cannot be safely moved back onto an unconsumed queue.
  end

  private

  def requeue_executions(table_name)
    return unless table_exists?(table_name)

    execute <<~SQL.squish
      UPDATE #{quote_table_name(table_name)}
      SET queue_name = #{quote(TARGET_QUEUE)}
      WHERE queue_name = #{quote(SOURCE_QUEUE)}
        AND job_id IN (
          SELECT id
          FROM solid_queue_jobs
          WHERE class_name = #{quote(MAIL_DELIVERY_JOB)}
            AND queue_name = #{quote(SOURCE_QUEUE)}
            AND finished_at IS NULL
        )
    SQL
  end
end
