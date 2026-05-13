class OperatorQuestionNudgeJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  NUDGE_AT = 27.days
  WINDOW = 0.04.days

  def perform
    Run.where(state: "awaiting_operator", nudge_sent: false)
       .where(created_at: window_start..window_end)
       .find_each do |run|
      nudge!(run)
    end
  end

  private

  def window_start
    (NUDGE_AT + WINDOW).ago
  end

  def window_end
    NUDGE_AT.ago
  end

  def nudge!(run)
    return unless run.awaiting_operator?
    return if run.nudge_sent?

    ChatChannel.for(run.job.repository).send_message(
      run: run,
      text: "Job ##{job_reference(run.job)} has been awaiting your response for 27 days; will auto-fail in 3 days if no reply.",
      context: {
        "kind" => "operator_question_nudge",
        "run_id" => run.id
      }
    )
    run.update!(nudge_sent: true)
  rescue StandardError => e
    Rails.logger.warn("[OperatorQuestionNudgeJob] nudge failed for Run ##{run.id}: #{e.class}: #{e.message}")
  end

  def job_reference(job)
    job.issue_number || job.id
  end
end
