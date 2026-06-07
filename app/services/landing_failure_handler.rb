class LandingFailureHandler
  INFRASTRUCTURE_BLOCKER_PATTERNS = [
    /\bENOSPC\b/i,
    /No space left on device/i,
    /Disk quota exceeded/i,
    /database or disk is full/i,
    /insufficient (?:disk|storage|space)/i,
    /not enough (?:disk|storage|space)/i
  ].freeze

  PERMISSION_BLOCKER_PATTERNS = [
    /Resource not accessible by integration/i,
    /missing (?:permission|scope|access)/i,
    /insufficient (?:permission|scope|access)/i,
    /permission denied/i,
    /\b403\b.*(?:forbidden|permission|resource not accessible)/i,
    /forbidden.*(?:permission|resource not accessible|integration)/i,
    /branch protection.*(?:permission|required|restrict)/i,
    /protected branch hook declined/i,
    /unable to access .* requested URL returned error: 403/i
  ].freeze

  MANUAL_BLOCKER_PATTERNS = [
    /rebase cap reached/i,
    /This branch can't be rebased/i,
    /manual intervention required/i,
    /operator intervention required/i
  ].freeze

  def self.call(...) = new(...).call

  def self.infrastructure_blocker?(reason)
    text = reason.to_s
    INFRASTRUCTURE_BLOCKER_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def self.permission_blocker?(reason)
    text = reason.to_s
    PERMISSION_BLOCKER_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def self.operator_required?(reason)
    text = reason.to_s
    infrastructure_blocker?(text) ||
      permission_blocker?(text) ||
      MANUAL_BLOCKER_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def self.pause_worthy_blocker?(reason)
    infrastructure_blocker?(reason) || permission_blocker?(reason)
  end

  def initialize(job:, reason:, run: nil)
    @job = job
    @reason = reason.to_s.presence || "auto_merge workflow failed"
    @run = run
  end

  def call
    return unless job&.landing?

    job.landing_failure_reason = reason.truncate(500)
    if pause_worthy_blocker?
      pause_landing!
      job.defer_landing! if job.may_defer_landing?
    elsif operator_required?
      log_operator_required!
      job.defer_landing! if job.may_defer_landing?
    else
      job.fail_landing! if job.may_fail_landing?
    end
    job.save! if job.changed?
  end

  private

  attr_reader :job, :reason, :run

  def pause_worthy_blocker?
    self.class.pause_worthy_blocker?(reason)
  end

  def operator_required?
    self.class.operator_required?(reason)
  end

  def pause_landing!
    unless job.user.landing_paused?
      job.user.update!(landing_paused: true)
      log_pause!
    end
  end

  def log_pause!
    log_run = run || job.current_run
    return unless log_run

    JobLog.append!(
      run: log_run,
      kind: "system",
      chunk: "landing_queue: paused landing because auto-merge hit an operator-required blocker; resume landing after clearing it (#{reason.truncate(180)})"
    )
  rescue StandardError => e
    Rails.logger.warn("[LandingFailureHandler] failed to log landing pause for Job ##{job.id}: #{e.class}: #{e.message}")
  end

  def log_operator_required!
    log_run = run || job.current_run
    return unless log_run

    JobLog.append!(
      run: log_run,
      kind: "system",
      chunk: "landing_queue: deferred landing because auto-merge hit an operator-required blocker; clear or override it before retrying (#{reason.truncate(180)})"
    )
  rescue StandardError => e
    Rails.logger.warn("[LandingFailureHandler] failed to log operator-required blocker for Job ##{job.id}: #{e.class}: #{e.message}")
  end
end
