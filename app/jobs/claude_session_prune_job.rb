class ClaudeSessionPruneJob < ApplicationJob
  queue_as :default

  # Daily housekeeping.
  # 1. Clear transcript_jsonl for any succeeded Runs that still have one
  #    (belt-and-suspenders — the Run#after_update_commit callback handles
  #    this immediately at transition time; this catches pre-deploy rows).
  # 2. Delete rows for terminal Runs older than RETAIN_AFTER_TERMINAL.
  #    Active Runs are never touched.
  def perform
    n_cleared = ClaudeSession.with_succeeded_transcript.update_all(transcript_jsonl: nil)
    Rails.logger.info("[ClaudeSessionPrune] cleared #{n_cleared} succeeded transcripts") if n_cleared > 0

    n_deleted = ClaudeSession.prunable.delete_all
    Rails.logger.info("[ClaudeSessionPrune] deleted #{n_deleted} sessions") if n_deleted > 0
  end
end
