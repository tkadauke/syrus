class RunHeartbeat
  DEFAULT_INTERVAL = 60.seconds
  BLOCKING_OPERATION_INTERVAL = 15.seconds
  MAX_RETRIES = 2
  MYSQL_LOCK_WAIT_TIMEOUT_SECONDS = 1
  RETRY_BACKOFF_RANGE_SECONDS = [ 0.025..0.075, 0.1..0.25 ].freeze
  RETRYABLE_ERRORS = [ ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked ].freeze

  def self.touch(run, now: Time.current, interval: DEFAULT_INTERVAL, force: false)
    return false unless run&.running?

    last = run.last_heartbeat_at
    return false if !force && last && (now - last) < interval

    scope = Run.where(id: run.id, finished_at: nil)
    scope = scope.where("last_heartbeat_at IS NULL OR last_heartbeat_at < ?", now - interval) unless force

    rows = with_contention_retry(run, now: now) do
      with_bounded_mysql_lock_wait { scope.update_all(last_heartbeat_at: now) }
    end
    return false unless rows

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

  def self.with_contention_retry(run, now:)
    retries = 0

    begin
      yield
    rescue *RETRYABLE_ERRORS => error
      exhausted = retries >= MAX_RETRIES
      log_contention(exhausted ? "exhausted" : "retry", run:, error:, attempt: retries + 1, exhausted:)
      unless exhausted
        sleep(rand(RETRY_BACKOFF_RANGE_SECONDS.fetch(retries)))
        retries += 1
        retry
      end

      if heartbeat_fresh?(run, now:)
        log_contention("skipped", run:, error:, attempt: retries + 1, exhausted: true)
        return nil
      end
      raise
    end
  end
  private_class_method :with_contention_retry

  def self.with_bounded_mysql_lock_wait
    connection = Run.connection
    return yield unless connection.adapter_name == "Mysql2"

    previous = connection.select_value("SELECT @@SESSION.innodb_lock_wait_timeout").to_i
    connection.execute("SET SESSION innodb_lock_wait_timeout = #{MYSQL_LOCK_WAIT_TIMEOUT_SECONDS}")
    yield
  ensure
    connection.execute("SET SESSION innodb_lock_wait_timeout = #{previous}") if defined?(previous) && previous
  end
  private_class_method :with_bounded_mysql_lock_wait

  def self.heartbeat_fresh?(run, now:)
    last_signal_at = run.last_heartbeat_at || run.started_at
    last_signal_at && last_signal_at >= now - Run::STALE_HEARTBEAT_THRESHOLD
  end
  private_class_method :heartbeat_fresh?

  def self.log_contention(action, run:, error:, attempt:, exhausted:)
    Rails.logger.warn({
      event: "run_heartbeat_contention",
      action: action,
      run_id: run.id,
      attempt: attempt,
      max_retries: MAX_RETRIES,
      exhausted: exhausted,
      heartbeat_age_seconds: run.last_heartbeat_at && (Time.current - run.last_heartbeat_at).round,
      error_class: error.class.name
    }.compact.to_json)
  end
  private_class_method :log_contention
end
