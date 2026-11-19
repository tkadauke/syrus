module Syrus
  # A SolidQueue worker that has begun a graceful shutdown keeps
  # heartbeating while it finishes in-flight jobs, but it never claims
  # another one. Without a marker it still looks like a live consumer, so
  # work routed to its private `worker-<hostname>` queue -- or a resume queue
  # only it serves -- sits unclaimed until the pod is finally gone and the
  # reconciler notices, which during a long drain is tens of minutes.
  #
  # The worker's stop hook stamps its process record; queue liveness and
  # worker routing treat a stamped process as no longer consuming.
  module QueueDrain
    METADATA_KEY = "draining_since".freeze

    module_function

    # The worker's own process record is private to SolidQueue; its id is the
    # public handle.
    def mark_process_id!(process_id, now: Time.current)
      return if process_id.blank?

      mark!(SolidQueue::Process.find_by(id: process_id), now: now)
    rescue StandardError => e
      Rails.logger.warn("[queue_drain] could not mark process draining: #{e.class}: #{e.message}")
    end

    def mark!(process, now: Time.current)
      return unless process

      process.update_columns(metadata: process.metadata.to_h.merge(METADATA_KEY => now.utc.iso8601))
    rescue StandardError => e
      # Never let bookkeeping break the shutdown itself; the reconciler still
      # catches the queue once the process stops heartbeating.
      Rails.logger.warn("[queue_drain] could not mark process draining: #{e.class}: #{e.message}")
    end

    def draining?(process)
      process.metadata.to_h[METADATA_KEY].present?
    end
  end
end
