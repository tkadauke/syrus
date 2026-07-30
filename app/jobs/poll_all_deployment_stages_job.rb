class PollAllDeploymentStagesJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  def perform
    return if AppSetting.polling_paused?

    Repository.active.find_each do |repository|
      plan = RepoDeploymentStagesReader.for_repository(repository)
      next unless plan.enabled?

      PollRepositoryDeploymentStagesJob.perform_later(repository.id)
    end
  end
end
