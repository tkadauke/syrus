class PruneOldNotificationsJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = Notification.prunable.delete_all
    Rails.logger.info("[PruneOldNotificationsJob] deleted #{deleted} notifications") if deleted > 0
  end
end
