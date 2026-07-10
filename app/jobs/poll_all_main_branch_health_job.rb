class PollAllMainBranchHealthJob < ApplicationJob
  include SkipIfPending

  queue_as :default

  def perform
    return if AppSetting.polling_paused?
    Repository.active.find_each do |repository|
      PollMainBranchHealthJob.perform_later(repository.id)
    end
  end
end
