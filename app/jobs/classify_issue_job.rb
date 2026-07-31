# Runs the ingestion classifier off the inline poll path.
#
# Before: PollRepositoryJob → Job.create! → IngestionClassifier.call
# (inline, agent subprocess in the same Ruby frame). A deploy SIGKILL
# during the agent call killed the codex process before Ruby could
# rescue, leaving the Job in `triaging / classifier_pending` with no
# retry path (subsequent polls dedup on the existing Job and skip).
#
# After: PollRepositoryJob enqueues ClassifyIssueJob.perform_later
# and returns immediately. SolidQueue's at-least-once delivery means
# a worker SIGKILL during classification leaves the SQ job in
# `pending` so the next worker picks it up and retries the classifier.
#
# Companion: ReapClassifierPendingJob (recurring) sweeps Jobs that
# slipped through the cracks anyway — anything still
# triaging/classifier_pending after a few minutes gets re-enqueued.
class ClassifyIssueJob < ApplicationJob
  queue_as :default

  # Same `runs` queue isn't right — the runs queue is reserved for
  # multi-minute agent invocations and is concurrency-limited so the
  # poller / reaper / app-event broadcasts don't starve. Classifier
  # invocations are short (10-60s typically) and shouldn't compete
  # with the dashboard's refresh cadence; default queue is the right
  # home.

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
  limits_concurrency to: 1, key: ->(job_id) { "classify:#{job_id}" }

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

    IngestionClassifier.call(job: job)
  end
end
