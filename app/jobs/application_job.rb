class ApplicationJob < ActiveJob::Base
  queue_as :control_plane

  around_perform do |job, block|
    PerformanceLogging.around_job(job) { block.call }
  end

  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError
end
