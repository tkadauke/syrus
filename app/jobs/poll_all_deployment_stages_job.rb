class PollAllDeploymentStagesJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?

    repository_ids = Repository.active.find_each.filter_map do |repository|
      plan = RepoDeploymentStagesReader.for_repository(repository)
      repository.id if plan.enabled?
    end
    PollRepositoryDeploymentStagesJob.perform_later_missing_simple_args(repository_ids.map { |id| [ id ] })
  end
end
