class SolidQueueCleanupJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  BATCH_SIZE = 100
  MAX_BATCHES = 10
  SLEEP_BETWEEN_BATCHES = 0.05

  def perform
    finished_before = SolidQueue.clear_finished_jobs_after.ago

    MAX_BATCHES.times do |index|
      records_deleted = SolidQueue::Job
                          .clearable(finished_before: finished_before)
                          .limit(BATCH_SIZE)
                          .delete_all
      break if records_deleted.zero?

      sleep(SLEEP_BETWEEN_BATCHES) unless index == MAX_BATCHES - 1
    end
  end
end
