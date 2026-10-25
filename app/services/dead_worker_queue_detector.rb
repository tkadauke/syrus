class DeadWorkerQueueDetector
  DEFAULT_GRACE_PERIOD = 5.minutes
  MAX_RESULTS = 100

  Result = Data.define(
    :job_id, :job_slug, :workflow_id, :workflow_slug, :run_id, :queue_name,
    :age_seconds, :claim_state, :run_state, :workflow_affinity_present
  )

  def self.call(...) = new(...).call

  def initialize(run_ids: nil, grace_period: DEFAULT_GRACE_PERIOD, limit: MAX_RESULTS, now: Time.current)
    @run_ids = Array(run_ids).map(&:to_i).select(&:positive?).uniq
    @grace_period = grace_period
    @limit = [ [ limit.to_i, 1 ].max, MAX_RESULTS ].min
    @now = now
  end

  def call
    scope = Run.where(state: "queued").includes(:job, step: :workflow).order(:created_at, :id)
    scope = scope.where(id: run_ids) if run_ids.any?
    results = []
    scope.find_in_batches(batch_size: 200) do |batch|
      batch.each do |run|
        result = detect(run)
        results << result if result
        return results if results.size >= limit
      end
    end
    results
  rescue NameError, ActiveRecord::StatementInvalid
    []
  end

  private

  attr_reader :run_ids, :grace_period, :limit, :now

  def detect(run)
    queue_job = Array(SolidQueueRunJobQuery.matching(
      scope: SolidQueue::Job.where(class_name: "RunJob", finished_at: nil).order(created_at: :desc),
      run_id: run.id,
      limit: 100
    )).find { |job| ready?(job) }
    return unless queue_job
    return unless queue_job.created_at && queue_job.created_at <= now - grace_period
    return unless explicit_worker_queue?(queue_job.queue_name)
    return if InstanceVersion.worker_queue_live?(queue_job.queue_name)
    return unless replacement_capacity_available?(run)

    workflow = run.workflow
    Result.new(
      job_id: run.job_id,
      job_slug: run.job&.slug,
      workflow_id: workflow&.id,
      workflow_slug: workflow&.slug,
      run_id: run.id,
      queue_name: queue_job.queue_name,
      age_seconds: (now - queue_job.created_at).to_i,
      claim_state: claim_state(queue_job),
      run_state: run.state,
      workflow_affinity_present: workflow&.worker_hostname.present? || workflow&.worker_storage_key.present?
    )
  end

  def explicit_worker_queue?(queue_name)
    queue_name.to_s.start_with?("worker-", "resume-")
  end

  def replacement_capacity_available?(run)
    replacement = RunQueueResolver.resolve(run: run, ignore_workflow_affinity: true)
    !replacement.blocked? && InstanceVersion.worker_queue_live?(replacement.queue_name)
  end

  def ready?(job)
    SolidQueue::ReadyExecution.where(job_id: job.id).exists?
  end

  def claim_state(job)
    return "claimed" if SolidQueue::ClaimedExecution.where(job_id: job.id).exists?
    return "ready" if ready?(job)
    return "scheduled" if SolidQueue::ScheduledExecution.where(job_id: job.id).exists?
    return "blocked" if SolidQueue::BlockedExecution.where(job_id: job.id).exists?

    "untracked"
  end
end
