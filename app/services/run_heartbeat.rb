class RunHeartbeat
  DEFAULT_INTERVAL = 60.seconds
  BLOCKING_OPERATION_INTERVAL = 15.seconds

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

  def self.during(run, interval: BLOCKING_OPERATION_INTERVAL)
    touch(run, force: true)
    heartbeat_thread = Thread.new do
      loop do
        sleep interval
        touch(run, force: true)
      rescue StandardError => e
        Rails.logger.warn("run heartbeat failed for RUN-#{run.id}: #{e.class}: #{e.message}")
      end
    end
    yield
  ensure
    heartbeat_thread&.kill
    heartbeat_thread&.join
    touch(run, force: true)
  end
end
