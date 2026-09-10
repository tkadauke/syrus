class PollAllMainBranchHealthJob < ApplicationJob
  include SkipIfPending

  queue_as :polling

  def perform(options = nil, target_selection_mode: "affected")
    target_selection_mode = options.to_h["target_selection_mode"].presence || target_selection_mode
    return if AppSetting.polling_paused?
    Repository.active.where(main_branch_health_enabled: true).find_each do |repository|
      if target_selection_mode == "affected"
        PollMainBranchHealthJob.perform_later(repository.id)
      else
        PollMainBranchHealthJob.perform_later(repository.id, target_selection_mode: target_selection_mode)
      end
    end
  end
end
