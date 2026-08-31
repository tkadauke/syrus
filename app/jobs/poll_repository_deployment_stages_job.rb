class PollRepositoryDeploymentStagesJob < ApplicationJob
  queue_as :polling

  LOOKBACK = (Integer(ENV["SYRUS_DEPLOYMENT_STAGE_POLL_LOOKBACK_DAYS"], exception: false) || 14).days
  MAX_JOBS_PER_POLL = Integer(ENV["SYRUS_DEPLOYMENT_STAGE_MAX_JOBS_PER_POLL"], exception: false) || 25

  limits_concurrency to: 1, key: ->(repo_id) { "deployment_stage_poll:#{repo_id}" }

  def perform(repository_id)
    return if AppSetting.polling_paused?

    repository = Repository.find_by(id: repository_id)
    return unless repository
    return if repository.archived?

    plan = RepoDeploymentStagesReader.for_repository(repository)
    return unless plan.enabled?

    jobs = jobs_with_missing_stage(repository, plan.stages)
    return if jobs.empty?

    recorded = DeploymentStageDetector.new(
      repository: repository,
      deployment_stages: plan.stages,
      jobs: jobs
    ).call
    Rails.logger.info("[PollRepositoryDeploymentStagesJob] #{repository.slug}: recorded #{recorded} deployment stage status(es)") if recorded.positive?
    Rails.logger.info("[PollRepositoryDeploymentStagesJob] #{repository.slug}: capped deployment stage poll at #{jobs.size} job(s)") if jobs.size >= MAX_JOBS_PER_POLL
  end

  private

  def jobs_with_missing_stage(repository, stages)
    stage_names = stages.map(&:name)
    missing_stage_sql = stage_names
      .map { "NOT EXISTS (SELECT 1 FROM job_deployment_stage_statuses WHERE job_deployment_stage_statuses.job_id = jobs.id AND job_deployment_stage_statuses.stage_name = ?)" }
      .join(" OR ")

    repository.jobs
      .where.not(landed_sha: [ nil, "" ])
      .where("jobs.finished_at IS NULL OR jobs.finished_at >= ?", LOOKBACK.ago)
      .where(missing_stage_sql, *stage_names)
      .order(finished_at: :desc, id: :desc)
      .limit(MAX_JOBS_PER_POLL)
      .to_a
  end
end
