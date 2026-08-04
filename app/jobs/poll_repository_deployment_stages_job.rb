class PollRepositoryDeploymentStagesJob < ApplicationJob
  queue_as :polling

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
  end

  private

  def jobs_with_missing_stage(repository, stages)
    stage_names = stages.map(&:name)

    repository.jobs
      .where.not(landed_sha: [ nil, "" ])
      .left_joins(:deployment_stage_statuses)
      .group("jobs.id")
      .having(
        "COUNT(DISTINCT CASE WHEN job_deployment_stage_statuses.stage_name IN (?) THEN job_deployment_stage_statuses.stage_name END) < ?",
        stage_names,
        stage_names.size
      )
      .to_a
  end
end
