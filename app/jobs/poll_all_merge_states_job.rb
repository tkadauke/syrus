class PollAllMergeStatesJob < ApplicationJob
  queue_as :default

  def perform
    return unless unified_poller_enabled?
    return if AppSetting.polling_paused?

    Job.joins(:repository)
       .merge(Repository.active)
       .where.not(pr_number: nil)
       .find_each do |job|
      PollMergeStateJob.perform_later(job.id)
    end
  end

  private

  def unified_poller_enabled?
    ActiveModel::Type::Boolean.new.cast(ENV["SYRUS_UNIFIED_MERGE_POLLER"])
  end
end
