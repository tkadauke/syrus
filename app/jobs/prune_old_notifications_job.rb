class PruneOldNotificationsJob < ApplicationJob
  include SkipIfPending

  queue_as :cleanup

  RETAIN_FOR = 30.days

  def perform
    cutoff = RETAIN_FOR.ago
    deleted = Notification.where("created_at < ?", cutoff).delete_all
    Rails.logger.info("[PruneOldNotificationsJob] deleted #{deleted} notifications older than #{cutoff.iso8601}") if deleted > 0
  end
end
