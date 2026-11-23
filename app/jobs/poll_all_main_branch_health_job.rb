class PollAllMainBranchHealthJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?

    repository_ids = Repository.active.with_main_branch_health_enabled.find_each.filter_map do |repository|
      repository.id unless repository.github_api_rate_limited_for?
    end
    PollMainBranchHealthJob.perform_later_missing_simple_args(repository_ids.map { |id| [ id ] })
  end
end
