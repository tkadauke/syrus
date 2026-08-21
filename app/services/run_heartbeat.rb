class RunHeartbeat
  DEFAULT_INTERVAL = 10.seconds

  def self.touch(run, now: Time.current, interval: DEFAULT_INTERVAL, force: false)
    return false unless run&.running?

    last = run.last_heartbeat_at
    return false if !force && last && (now - last) < interval

    rows = Run.where(id: run.id, finished_at: nil).update_all(last_heartbeat_at: now)
    run.last_heartbeat_at = now if rows.positive?
    rows.positive?
  end
end
