class RunHeartbeat
  DEFAULT_INTERVAL = 30.seconds

  def self.touch(run, now: Time.current, interval: DEFAULT_INTERVAL, force: false)
    return false unless run&.running?

    last = run.last_heartbeat_at
    return false if !force && last && (now - last) < interval

    scope = Run.where(id: run.id, finished_at: nil)
    scope = scope.where("last_heartbeat_at IS NULL OR last_heartbeat_at < ?", now - interval) unless force

    rows = scope.update_all(last_heartbeat_at: now)
    run.last_heartbeat_at = now if rows.positive?
    rows.positive?
  end
end
