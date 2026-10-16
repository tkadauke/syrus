class PruneOldNotificationsJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  def perform
    deleted = RetentionPruner.call(scope: Notification.prunable)
    Rails.logger.info("[PruneOldNotificationsJob] deleted #{deleted} notifications") if deleted > 0
  end
end
