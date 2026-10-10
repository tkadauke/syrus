# Runs the ingestion classifier off the inline poll path.
#
# Before: PollRepositoryJob → Job.create! → IngestionClassifier.call
# (inline, agent subprocess in the same Ruby frame). A deploy SIGKILL
# during the agent call killed the codex process before Ruby could
# rescue, leaving the Job in `triaging / classifier_pending` with no
# retry path (subsequent polls dedup on the existing Job and skip).
#
# After: PollRepositoryJob enqueues ClassifyIssueJob.enqueue_for_job!
# and returns immediately. SolidQueue's at-least-once delivery covers
# ordinary worker loss, and the enqueue helper recovers the pruner's
# FailedExecution shape before it can strand the classifier key.
#
# Companion: WorkEngine::Reconciler detects Jobs stuck
# triaging/classifier_pending and plans a `reclassify_stalled_intake` repair,
# which re-enqueues this job. That used to be ReapClassifierPendingJob -- a
# private copy of the stale-work reaping the reconciler already does, which
# existed only because classification is not a Run the reconciler could see.
class ClassifyIssueJob < ApplicationJob
  queue_as :control_plane

  # Same `runs` queue isn't right — the runs queue is reserved for
  # multi-minute agent invocations and is concurrency-limited so the
  # poller / reaper / app-event broadcasts don't starve. Classifier
  # invocations are short (10-60s typically) and shouldn't compete
  # with the dashboard's refresh cadence; control_plane is the right
  # lane because classifier completion gates initial workflow dispatch.

  # Don't pile up retries on a Job that's been deleted, closed, or
  # already advanced. RecordNotFound is the only retry-pointless
  # error class — everything else (rate limits, transient codex
  # errors) benefits from SolidQueue's default retry policy.
  discard_on ActiveRecord::RecordNotFound

  # One classify in flight per Job. Without this, the recurring
  # reaper could enqueue a second classify while the first is still
  # running with the codex agent — two agents racing on the same
  # Job's transition is the kind of thing that turns one stuck Job
  # into N stuck Jobs.
  EnqueueResult = Data.define(:active_job, :provider_job_id, :recovered_failed_execution_ids)

  class EnqueueBlockedError < StandardError
    attr_reader :job_id, :concurrency_key, :blocking_solid_queue_job_ids

    def initialize(job_id:, concurrency_key:, blocking_solid_queue_job_ids:)
      @job_id = job_id
      @concurrency_key = concurrency_key
      @blocking_solid_queue_job_ids = blocking_solid_queue_job_ids
      super(
        "ClassifyIssueJob for Job ##{job_id} is blocked by failed " \
        "SolidQueue job(s) #{blocking_solid_queue_job_ids.join(', ')} on #{concurrency_key}"
      )
    end
  end

  limits_concurrency to: 1, key: ->(job_id) { ::ClassifyIssueJob.concurrency_key_for(job_id) }

  class << self
    def concurrency_key_for(job_id)
      "classify:#{job_id}"
    end

    def solid_queue_concurrency_key_for(job_id)
      "#{name}/#{concurrency_key_for(job_id)}"
    end

    def enqueue_for_job!(job_or_id)
      job_id = job_or_id.respond_to?(:id) ? job_or_id.id : job_or_id
      key = solid_queue_concurrency_key_for(job_id)
      recovered_ids = recover_pruned_failed_execution!(key)
      active_job = perform_later(job_id)
      provider_job_id = active_job&.provider_job_id
      blocked_by_failed_ids = unrecovered_failed_blocker_ids(key, provider_job_id)
      if blocked_by_failed_ids.any?
        discard_blocked_enqueue(provider_job_id)
        raise EnqueueBlockedError.new(
          job_id: job_id,
          concurrency_key: key,
          blocking_solid_queue_job_ids: blocked_by_failed_ids
        )
      end

      EnqueueResult.new(
        active_job: active_job,
        provider_job_id: provider_job_id,
        recovered_failed_execution_ids: recovered_ids
      )
    end

    private

    def recover_pruned_failed_execution!(concurrency_key)
      return [] unless solid_queue_model?("SolidQueue::FailedExecution")

      failed_jobs = pruned_failed_jobs(concurrency_key).to_a
      return [] if failed_jobs.empty?

      recovered_failed_execution_ids = failed_jobs.filter_map { |job| job.failed_execution&.id }

      SolidQueue::Job.transaction do
        failed_jobs.each do |solid_queue_job|
          solid_queue_job.failed_execution&.destroy!
          solid_queue_job.destroy!
        end

        if no_live_execution_for_key?(concurrency_key)
          if solid_queue_model?("SolidQueue::Semaphore")
            SolidQueue::Semaphore.where(key: concurrency_key).delete_all
          end
          if solid_queue_model?("SolidQueue::BlockedExecution")
            SolidQueue::BlockedExecution.release_one(concurrency_key)
          end
        end
      end

      recovered_failed_execution_ids
    rescue ActiveRecord::StatementInvalid, NameError => e
      Rails.logger.warn(
        "[ClassifyIssueJob] failed to recover pruned SolidQueue execution " \
        "for #{concurrency_key}: #{e.class}: #{e.message}"
      )
      []
    end

    def unrecovered_failed_blocker_ids(concurrency_key, provider_job_id)
      return [] unless provider_job_id && solid_queue_model?("SolidQueue::BlockedExecution")
      return [] unless SolidQueue::BlockedExecution.exists?(job_id: provider_job_id)

      failed_jobs_for_key(concurrency_key).map(&:id)
    rescue ActiveRecord::StatementInvalid, NameError => e
      Rails.logger.warn(
        "[ClassifyIssueJob] failed to inspect SolidQueue blocker " \
        "for #{concurrency_key}: #{e.class}: #{e.message}"
      )
      []
    end

    def discard_blocked_enqueue(provider_job_id)
      return unless provider_job_id && solid_queue_model?("SolidQueue::Job")

      if solid_queue_model?("SolidQueue::BlockedExecution")
        SolidQueue::BlockedExecution.where(job_id: provider_job_id).delete_all
      end
      SolidQueue::Job.where(id: provider_job_id).delete_all
    rescue ActiveRecord::StatementInvalid, NameError => e
      Rails.logger.warn(
        "[ClassifyIssueJob] failed to discard blocked enqueue " \
        "#{provider_job_id}: #{e.class}: #{e.message}"
      )
    end

    def pruned_failed_jobs(concurrency_key)
      failed_jobs_for_key(concurrency_key).select do |solid_queue_job|
        error = solid_queue_job.failed_execution&.error
        error.to_s.include?("ProcessPrunedError")
      end
    end

    def failed_jobs_for_key(concurrency_key)
      SolidQueue::Job
        .includes(:failed_execution)
        .where(class_name: name, concurrency_key: concurrency_key, finished_at: nil)
        .select { |solid_queue_job| solid_queue_job.failed_execution.present? }
    end

    def no_live_execution_for_key?(concurrency_key)
      unless solid_queue_model?("SolidQueue::ReadyExecution") &&
          solid_queue_model?("SolidQueue::ClaimedExecution")
        return true
      end

      live_job_ids = SolidQueue::Job
        .where(class_name: name, concurrency_key: concurrency_key, finished_at: nil)
        .select(:id)
      !SolidQueue::ReadyExecution.where(job_id: live_job_ids).exists? &&
        !SolidQueue::ClaimedExecution.where(job_id: live_job_ids).exists?
    end

    def solid_queue_model?(name)
      name.safe_constantize&.table_exists?
    end
  end

  def perform(job_id)
    job = Job.find(job_id)

    # Pre-flight guards — these were the inline checks in
    # PollRepositoryJob#classify_if_available, lifted here so the
    # SolidQueue job is the single owner of "should the classifier
    # run". The reaper enqueues without re-checking; the job
    # short-circuits cleanly if conditions changed since enqueue.
    return unless job.triaging? && job.triaging_reason_classifier_pending?
    provider = job.workflow_agent_provider
    unless job.user.agent_provider_configured?(provider)
      Rails.logger.warn("[ClassifyIssueJob] #{job.slug}: agent provider " \
                        "#{provider.inspect} not configured for user " \
                        "#{job.user.id}; deferring")
      return
    end

    result = IngestionClassifier.call(job: job)
    enqueue_retry_if_still_pending!(job, result)
  end

  private

  def enqueue_retry_if_still_pending!(job, result)
    return unless result.respond_to?(:success?) && !result.success?

    job.reload
    return unless job.triaging? && job.triaging_reason_classifier_pending?
    return unless job.classifier_attempts < Job::MAX_CLASSIFIER_ATTEMPTS

    self.class.enqueue_for_job!(job)
  rescue EnqueueBlockedError => e
    Rails.logger.warn("[ClassifyIssueJob] #{job.slug}: classifier retry blocked: #{e.message}")
  end
end
