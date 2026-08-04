class PollAllRepositoriesJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?
    Repository.active.where(polling_enabled: true).find_each do |repository|
      PollRepositoryJob.perform_later(repository.id)
    end
  end
end
