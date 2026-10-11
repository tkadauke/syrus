# Warms the cached cognitive-debt rollup for every polled repository so the
# repository page serves it from cache instead of computing a full
# DiffReviewVersion walk per request. See App::CognitiveDebtPayload.
class RefreshCognitiveDebtSnapshotsJob < ApplicationJob
  queue_as :low_priority_maintenance

  def perform
    Repository.where(polling_enabled: true).find_each do |repository|
      App::CognitiveDebtPayload.refresh!(repository: repository)
    rescue StandardError => e
      # One repository's rollup must not stop the rest being warmed; a stale
      # entry simply falls back to computing inline on the next request.
      Rails.logger.warn("[RefreshCognitiveDebtSnapshotsJob] #{repository.slug}: #{e.class}: #{e.message}")
    end
  end
end
