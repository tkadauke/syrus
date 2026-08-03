class PollAllExternalOpenPrsJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  def perform
    return if AppSetting.polling_paused?
    Repository.active.where(external_pr_ingestion_enabled: true).find_each do |repository|
      PollExternalOpenPrsJob.perform_later(repository.id)
    end
  end
end
