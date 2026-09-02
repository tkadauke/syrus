class LandingQueueProcessorJob < ApplicationJob
  queue_as :control_plane

  limits_concurrency to: 1, key: -> { "landing_queue_processor" }

  LOCK_RETRY_ERRORS = [
    ActiveRecord::Deadlocked,
    ActiveRecord::LockWaitTimeout
  ].freeze
  LOCK_RETRY_ATTEMPTS = 3
  LOCK_RETRY_DELAY = 5.seconds

  def perform
    return if AppSetting.polling_paused?

    attempts = 0

    begin
      LandingQueueProcessor.call
    rescue *LOCK_RETRY_ERRORS => e
      attempts += 1
      if attempts <= LOCK_RETRY_ATTEMPTS
        Rails.logger.warn(
          "[LandingQueueProcessorJob] lock conflict (#{e.class}); " \
          "retrying attempt #{attempts}/#{LOCK_RETRY_ATTEMPTS}"
        )
        sleep(0.05 * attempts) unless Rails.env.test?
        retry
      end

      Rails.logger.warn(
        "[LandingQueueProcessorJob] lock conflict persisted (#{e.class}); " \
        "queueing landing processor retry"
      )
      self.class.set(wait: LOCK_RETRY_DELAY).perform_later
      WorkEngine::Reconciler.request(source: "#{self.class.name}.lock_conflict")
      nil
    end
  end
end
