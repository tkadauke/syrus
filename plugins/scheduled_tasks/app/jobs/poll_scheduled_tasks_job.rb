class PollScheduledTasksJob < Syrus::Host::PluginJob
  plugin :scheduled_tasks
  queue_as :polling
  include Syrus::Host::SkipIfPending

  # Raised when a poll-wide database phase keeps failing after bounded
  # retries. It is re-raised (never swallowed) so the poll is recorded as
  # failed; the next minute's poll fires whatever is still due.
  class ScanFailed < StandardError; end

  BATCH_SIZE = 200
  MAX_ATTEMPTS = 3
  RETRY_BASE_DELAY = 0.2

  TRANSIENT_ERROR_PATTERN = /Out of sort memory|Lock wait timeout|Deadlock found/i

  # Recurring scheduler for ScheduledTask. Runs every minute, scans
  # alive+active tasks, hands the ones whose next scheduled time has
  # arrived to ScheduledTasks::Fire (which applies the pr_pileup_policy,
  # spawns the cron Job, and stamps last_fired_at).
  #
  # The scan is deliberately join-free and sort-free: tasks are read in
  # bounded primary-key-cursor pages, then repository/user eligibility is
  # checked per page against small id sets. Every database
  # phase is read-only, so it can be retried safely; firing is never retried
  # here and stays idempotent through Fire's own due check.
  def perform
    return if Syrus::Host::AppSetting.polling_paused?
    now = Time.current

    cursor = 0
    loop do
      page = with_retry(:load_page) { load_page(cursor) }
      break if page.empty?

      cursor = page.last.id
      eligible(page).each { |task| process_task(task, now) }
      break if page.size < BATCH_SIZE
    end
  end

  private

  # One bounded, primary-key-cursor page: `id > cursor ORDER BY id LIMIT n`
  # walks the primary key, so MySQL needs no filesort and each read and its
  # in-memory result are capped at BATCH_SIZE rows regardless of table size.
  def load_page(cursor)
    ScheduledTasks::Task.alive.where(state: "scheduled")
                        .where(ScheduledTasks::Task.arel_table[:id].gt(cursor))
                        .order(:id).limit(BATCH_SIZE).to_a
  end

  def eligible(tasks)
    with_retry(:check_eligibility) do
      repo_ids = Syrus::Host::RepositoryRecord.active.where(id: tasks.map(&:repository_id).uniq).pluck(:id)
      user_ids = Syrus::Host::UserRecord.where(id: tasks.map(&:user_id).uniq, scheduling_paused: false).pluck(:id)
      tasks.select { |t| repo_ids.include?(t.repository_id) && user_ids.include?(t.user_id) }
    end
  end

  def process_task(task, now)
    return unless task.due?(now: now)

    result = ScheduledTasks::Fire.new(task, now: now, require_due: true).call
    if result.skipped
      Rails.logger.info("[PollScheduledTasksJob] task ##{task.id} skipped: #{result.reason}")
    else
      Rails.logger.info("[PollScheduledTasksJob] task ##{task.id} fired → #{result.job.slug}")
    end
  rescue StandardError => e
    begin
      task.record_fire_failure!(e, at: now)
    rescue StandardError => recording_error
      Rails.logger.error(
        "[PollScheduledTasksJob] task ##{task.id} failure record failed: " \
        "#{recording_error.class}: #{recording_error.message}"
      )
    end
    Syrus::Host::BackendExceptionLogging.ingest_job(
      { job: self, exception_object: e, exception: [ e.class.name, e.message ] },
      0
    )
    Rails.logger.warn("[PollScheduledTasksJob] task ##{task.id} fire failed: #{e.class}: #{e.message}")
  end

  # Retries a read-only poll phase on transient MySQL capacity/lock errors.
  # On exhaustion (or a non-transient error) the failure is logged with its
  # phase and attempt count and re-raised so the poll never reports success.
  def with_retry(phase)
    attempt = 0
    begin
      attempt += 1
      yield
    rescue ActiveRecord::StatementInvalid, ActiveRecord::LockWaitTimeout, ActiveRecord::Deadlocked => e
      transient = transient_error?(e)
      if transient && attempt < MAX_ATTEMPTS
        Rails.logger.warn(
          "[PollScheduledTasksJob] phase=#{phase} attempt=#{attempt}/#{MAX_ATTEMPTS} " \
          "transient #{e.class}: #{e.message.to_s.truncate(200)}; retrying"
        )
        sleep(RETRY_BASE_DELAY * attempt)
        retry
      end

      outcome = transient ? "retries_exhausted" : "non_transient"
      Rails.logger.error(
        "[PollScheduledTasksJob] phase=#{phase} attempts=#{attempt} outcome=#{outcome} " \
        "#{e.class}: #{e.message.to_s.truncate(200)}"
      )
      raise ScanFailed, "poll phase #{phase} failed (#{outcome}) after #{attempt} attempt(s): #{e.class}: #{e.message.to_s.truncate(200)}"
    end
  end

  def transient_error?(error)
    error.is_a?(ActiveRecord::LockWaitTimeout) ||
      error.is_a?(ActiveRecord::Deadlocked) ||
      error.message.to_s.match?(TRANSIENT_ERROR_PATTERN)
  end
end
