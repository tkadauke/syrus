class PollAllMainBranchHealthJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform
    return if AppSetting.polling_paused?
    Repository.active.where(main_branch_health_enabled: true).find_each do |repository|
      PollMainBranchHealthJob.perform_later(repository.id)
    end
  end
end
