class PollAllExternalOpenPrsJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?
    Repository.active.where(external_pr_ingestion_enabled: true).find_each do |repository|
      next if repository.github_api_rate_limited_for?

      PollExternalOpenPrsJob.perform_later(repository.id)
    end
  end
end
