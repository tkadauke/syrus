class SolidQueueCleanupJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  BATCH_SIZE = 100
  MAX_BATCHES = 10
  SLEEP_BETWEEN_BATCHES = 0.05
  STALE_READY_JOB_AGE = 7.days
  OBSOLETE_READY_QUEUE_NAMES = [ "default" ].freeze
  OBSOLETE_READY_QUEUE_PREFIXES = [ "resume-" ].freeze

  def perform
    prune_finished_jobs
    prune_obsolete_ready_jobs
  end

  private

  def prune_finished_jobs
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

  def prune_obsolete_ready_jobs
    stale_ready_cutoff = STALE_READY_JOB_AGE.ago

    MAX_BATCHES.times do |index|
      job_ids = obsolete_ready_job_scope(stale_ready_cutoff).limit(BATCH_SIZE).pluck(:id)
      break if job_ids.empty?

      SolidQueue::ReadyExecution.where(job_id: job_ids).delete_all
      SolidQueue::Job.where(id: job_ids).delete_all

      sleep(SLEEP_BETWEEN_BATCHES) unless index == MAX_BATCHES - 1
    end
  end

  def obsolete_ready_job_scope(stale_ready_cutoff)
    ready_table = SolidQueue::ReadyExecution.quoted_table_name
    queue_predicates = OBSOLETE_READY_QUEUE_NAMES.map do |queue_name|
      ActiveRecord::Base.sanitize_sql_array([ "#{ready_table}.queue_name = ?", queue_name ])
    end
    queue_predicates += OBSOLETE_READY_QUEUE_PREFIXES.map do |prefix|
      ActiveRecord::Base.sanitize_sql_array([ "#{ready_table}.queue_name LIKE ?", "#{prefix}%" ])
    end

    SolidQueue::Job
      .joins(:ready_execution)
      .where("#{ready_table}.created_at < ?", stale_ready_cutoff)
      .where(queue_predicates.join(" OR "))
  end
end
