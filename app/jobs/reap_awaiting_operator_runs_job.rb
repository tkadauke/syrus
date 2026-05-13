class ReapAwaitingOperatorRunsJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  TIMEOUT = 30.days
  OUTCOME = "operator_unresponsive".freeze

  def perform
    cutoff = TIMEOUT.ago

    Run.where(state: "awaiting_operator")
       .where("created_at < ?", cutoff)
       .find_each do |run|
      reap!(run)
    end
  end

  private

  def reap!(run)
    return unless run.may_fail?

    run.agent_outcome = OUTCOME
    run.fail!
    run.save!

    if run.step&.may_fail?
      run.step.fail!
      run.step.save!
    end

    close_job!(run.job)
  rescue StandardError => e
    Rails.logger.warn("[ReapAwaitingOperatorRunsJob] reap failed for Run ##{run.id}: #{e.class}: #{e.message}")
  end

  def close_job!(job)
    return unless job.open?

    job.close_with_reason!(OUTCOME)
  end
end
