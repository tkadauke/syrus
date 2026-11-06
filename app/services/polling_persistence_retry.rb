class PollingPersistenceRetry
  MAX_RETRIES = 2
  BACKOFF_SECONDS = [ 0.05, 0.2 ].freeze
  RETRYABLE_ERRORS = [
    ActiveRecord::LockWaitTimeout,
    ActiveRecord::Deadlocked
  ].freeze

  def self.call(job:, boundary:)
    retries = 0

    begin
      yield(retries)
    rescue *RETRYABLE_ERRORS => error
      exhausted = retries >= MAX_RETRIES
      log(error:, job:, boundary:, retry_number: retries + 1, exhausted: exhausted)
      raise if exhausted

      sleep(BACKOFF_SECONDS.fetch(retries))
      retries += 1
      retry
    end
  end

  def self.log(error:, job:, boundary:, retry_number:, exhausted:)
    Rails.logger.warn(
      {
        event: "github_polling_persistence_contention",
        boundary: boundary,
        job_id: job.id,
        job_slug: job.slug,
        repository_id: job.repository_id,
        retry_number: retry_number,
        max_retries: MAX_RETRIES,
        exhausted: exhausted,
        error_class: error.class.name,
        error_message: error.message
      }.to_json
    )
  end
  private_class_method :log
end
