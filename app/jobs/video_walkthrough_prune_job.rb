# Media lifecycle for walkthrough videos. Each is 10s-100s of MB and lives in
# the syrus-data volume (Active Storage Disk service) or S3/minio — bounded
# only by the host disk / bucket. On a busy multi-user instance they would
# accumulate without limit, so this job enforces TWO ceilings on the stored
# (post-transcode) video blobs:
#
#   1. Time — purge blobs from settled walkthroughs older than
#      AppSetting.video_retention_days (default 7). Past that a walkthrough
#      can't be retried, which for a week-old recording is the right trade.
#   2. Size — if total stored video bytes exceed
#      AppSetting.video_storage_budget_bytes (default 2 GB; 0 = unlimited),
#      purge oldest-first (LRU) until back under budget.
#
# In BOTH cases only the heavy video blob is removed. The analysis JSON and
# the issue screenshots (attached to the chat turn) persist — they're the
# durable value. "Archive" here means the record survives, the media doesn't.
# Runs daily on `cleanup`.
class VideoWalkthroughPruneJob < ApplicationJob
  queue_as :cleanup

  # Only videos from SETTLED walkthroughs are candidates — never purge one
  # that's mid-analysis (its blob is in use).
  def perform
    time_sweep
    size_sweep
  end

  private

  def time_sweep
    days = AppSetting.video_retention_days.to_i
    # Defense in depth against the destructive-cutoff footgun: AppSetting
    # validates days >= 1, but a direct DB edit (or a future bypass) with 0 or
    # negative would make `days.days.ago` land at/after now and purge every
    # settled video. Never time-sweep on a non-positive retention.
    return unless days.positive?

    cutoff = days.days.ago
    purged = 0
    settled_with_blob.where("chat_video_walkthroughs.updated_at < ?", cutoff).find_each do |walkthrough|
      purge_video!(walkthrough)
      purged += 1
    end
    log("time sweep purged #{purged} video(s) older than #{days}d") if purged.positive?
  end

  def size_sweep
    budget = AppSetting.video_storage_budget_bytes
    return if budget.zero?

    # Oldest-updated first — LRU that keeps the freshest videos retriable. NOTE:
    # find_each can't do this — it ignores a non-primary-key .order and forces
    # batch-by-id, which is NOT updated_at order once a row is re-touched (a
    # retried walkthrough keeps its id but gets a newer updated_at). So pluck
    # the ordered (id, byte_size) candidates and pick the eviction set in Ruby.
    # Columns are table-qualified because the blob join also has id/byte_size;
    # the pluck is two integers per row, cheap even for thousands of videos.
    candidates = settled_with_blob
      .order(Arel.sql("chat_video_walkthroughs.updated_at ASC, chat_video_walkthroughs.id ASC"))
      .pluck("chat_video_walkthroughs.id", "chat_video_walkthroughs.byte_size")
    total = candidates.sum { |(_id, bytes)| bytes.to_i }
    return if total <= budget

    evict = []
    candidates.each do |(id, bytes)|
      break if total <= budget

      total -= bytes.to_i
      evict << id
    end
    return if evict.empty?

    ChatVideoWalkthrough.where(id: evict).find_each { |walkthrough| purge_video!(walkthrough) }
    log("size sweep purged #{evict.size} video(s) to fit the #{budget / 1024 / 1024}MB budget")
  end

  # Only rows whose blob is still attached can be purged; the join keeps the
  # sum/scan honest as blobs disappear.
  def settled_with_blob
    ChatVideoWalkthrough
      .where(state: %w[analyzed failed])
      .joins(file_attachment: :blob)
  end

  def purge_video!(walkthrough)
    walkthrough.file.purge_later if walkthrough.file.attached?
  end

  def log(message)
    Rails.logger.info("[VideoWalkthroughPruneJob] #{message}")
  end
end
