class PollAllRepositoriesJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?

    repository_ids = Repository.active.where(polling_enabled: true).filter_map do |repository|
      repository.id unless repository.github_api_rate_limited_for?
    end
    PollRepositoryJob.perform_later_missing_simple_args(repository_ids.map { |id| [ id ] })
  end
end
