class PollAllExternalOpenPrsJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?

    repository_ids = Repository.active.where(external_pr_ingestion_enabled: true).find_each.filter_map do |repository|
      repository.id unless repository.github_api_rate_limited_for?
    end
    PollExternalOpenPrsJob.perform_later_missing_simple_args(repository_ids.map { |id| [ id ] })
  end
end
