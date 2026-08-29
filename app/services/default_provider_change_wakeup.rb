class DefaultProviderChangeWakeup
  Result = Data.define(:job_ids, :released_work_unit_ids, :skipped_auto_retry_attempt_ids) do
    def job_count = job_ids.size
  end

  def self.call(...) = new(...).call

  def initialize(user:, previous_provider:, current_provider:)
    @user = user
    @previous_provider = previous_provider.to_s.presence
    @current_provider = current_provider.to_s.presence
  end

  def call
    broadcast_provider_changes
    return Result.new(job_ids: [], released_work_unit_ids: [], skipped_auto_retry_attempt_ids: []) unless provider_changed?

    job_ids = []
    released_work_unit_ids = []
    skipped_auto_retry_attempt_ids = []

    affected_jobs.find_each do |job|
      next unless job.workflow_agent_provider == current_provider

      job_ids << job.id
      released_work_unit_ids.concat(release_stale_work_units(job))
      skipped_ids = skip_stale_provider_retry_attempts(job)
      skipped_auto_retry_attempt_ids.concat(skipped_ids)
      WorkEngine::Reconciler.request(source: self.class.name, job: job) if skipped_ids.any? || quota_failed_on_previous_provider?(job)
    end

    Result.new(
      job_ids: job_ids,
      released_work_unit_ids: released_work_unit_ids,
      skipped_auto_retry_attempt_ids: skipped_auto_retry_attempt_ids
    )
  end

  private

  attr_reader :user, :previous_provider, :current_provider

  def provider_changed?
    previous_provider.present? && current_provider.present? && previous_provider != current_provider
  end

  def broadcast_provider_changes
    App::ProviderAvailability.broadcast_changed(user: user, provider: previous_provider) if previous_provider.present?
    App::ProviderAvailability.broadcast_changed(user: user, provider: current_provider) if current_provider.present?
  end

  def affected_jobs
    Job
      .open_threads
      .where(job_provider_setting: "default")
      .effectively_owned_by(user)
      .includes(:repository, :owner_user, :user)
  end

  def release_stale_work_units(job)
    before = stale_work_unit_ids(job)
    WorkUnits::StaleProviderRelauncher.release_for_job!(job)
    before
  end

  def stale_work_unit_ids(job)
    WorkUnit
      .joins(:work_unit_members)
      .where(work_unit_members: { job_id: job.id })
      .where(state: WorkIntents::TerminalUnitSync::ACTIVE_UNIT_STATES)
      .includes(workflow: :job)
      .select { |unit| WorkUnits::StaleProviderRelauncher.stale?(unit) }
      .map(&:id)
  end

  def skip_stale_provider_retry_attempts(job)
    AutoRetryAttempt
      .pending
      .where(
        job: job,
        agent_provider: previous_provider,
        failure_classification: ProviderUsageLimit::CLASSIFICATION
      )
      .map do |attempt|
        attempt.skip_stale_pending!(stale_attempt_reason)
        attempt.id
      end
  end

  def quota_failed_on_previous_provider?(job)
    job.runs
      .includes(:run_failure_classification)
      .where(state: "failed", agent_provider: previous_provider)
      .order(finished_at: :desc, id: :desc)
      .limit(5)
      .any? do |run|
        run.agent_outcome.to_s == ProviderUsageLimit::OUTCOME ||
          run.run_failure_classification&.classification == ProviderUsageLimit::CLASSIFICATION
      end
  end

  def stale_attempt_reason
    "default provider changed from #{previous_provider} to #{current_provider}; reconciler will retry with #{current_provider}"
  end
end
