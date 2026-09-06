class LandingFailureHandler
  INFRASTRUCTURE_BLOCKER_PATTERNS = [
    /\bENOSPC\b/i,
    /No space left on device/i,
    /Disk quota exceeded/i,
    /database or disk is full/i,
    /insufficient (?:disk|storage|space)/i,
    /not enough (?:disk|storage|space)/i
  ].freeze

  # Conditions that say nothing about whether the work is landable -- GitHub
  # having a bad minute, an MCP sidecar that did not come up, a worker that
  # died, another WorkUnit holding the lock we wanted.
  #
  # These used to fall through to `fail_landing`, which reverts the Job to
  # :implemented and clears its approval, so a five-second GitHub outage cost
  # an operator a round of re-approving every member of a train. They are
  # deferrals: the Job stays :approved and the landing queue tries again.
  #
  # Distinct from INFRASTRUCTURE_BLOCKER_PATTERNS, which additionally pause
  # landing instance-wide -- right for a full disk, far too heavy for a 502.
  TRANSIENT_BLOCKER_PATTERNS = [
    /No server is currently available to service your request/i,
    /\b50[0234]\b[^\n]*(?:Bad Gateway|Service Unavailable|Gateway Time-?out|Server Error)/i,
    /Octokit::(?:BadGateway|ServiceUnavailable|InternalServerError)/,
    /\bmcp_sidecar_failed\b/i,
    /\bworker_died\b/i,
    /already owns lock\b/i,
    /\bECONNRESET\b|\bETIMEDOUT\b|\bEHOSTUNREACH\b/i,
    /execution expired/i
  ].freeze

  def self.transient_blocker?(reason)
    text = reason.to_s
    TRANSIENT_BLOCKER_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def self.call(...) = new(...).call

  def self.infrastructure_blocker?(reason)
    text = reason.to_s
    INFRASTRUCTURE_BLOCKER_PATTERNS.any? { |pattern| text.match?(pattern) }
  end

  def initialize(job:, reason:, run: nil, problem: nil)
    @job = job
    @reason = reason.to_s.presence || "auto_merge workflow failed"
    @run = run
    @problem = problem
  end

  def call
    return unless job&.landing?

    job.landing_failure_reason = reason.truncate(500)
    if infrastructure_blocker?
      pause_landing!
      job.defer_landing! if job.may_defer_landing?
    elsif rebase_cap_blocker? || merge_train_rebuild_required? || landing_start_blocker? || transient_blocker?
      log_deferral!
      job.defer_landing! if job.may_defer_landing?
    else
      job.fail_landing! if job.may_fail_landing?
    end
    job.save! if job.changed?
  end

  private

  attr_reader :job, :reason, :run

  # What the failing step said the problem was, when it said anything.
  #
  # This used to be inferred by matching `reason` against two anchored
  # patterns, which failed in both directions: RunJob prefixes the reason with
  # the exception class (so `\A` never matched), and steps raise nine other
  # "rebuild required" messages the patterns did not list. The step now
  # declares a Problem and it is read here; the patterns stay only as a
  # fallback for reasons that never came from a step at all.
  def problem
    return @problem if @problem || @problem_resolved

    @problem_resolved = true
    # Queried directly, not through `run.run_diagnostic`: CaptureRunDiagnostic
    # creates the row with create_or_find_by!, which leaves an already-loaded
    # association cached as nil on the very Run we are asked about.
    code = RunDiagnostic.where(run_id: run.id).pick(:problem_code) if run
    @problem = Problem.resolve(code) if code.present?
  end

  def problem_code = problem&.code

  def infrastructure_blocker?
    self.class.infrastructure_blocker?(reason)
  end

  def rebase_cap_blocker?
    reason.match?(/rebase cap reached/i)
  end

  def merge_train_rebuild_required?
    return true if problem_code == "merge_train_rebuild_required"

    self.class.merge_train_rebuild_required?(reason)
  end

  def landing_start_blocker?
    reason.match?(/\Alanding start blocked: /i)
  end

  def transient_blocker?
    self.class.transient_blocker?(reason)
  end

  def self.stale_merge_train_base?(reason)
    merge_train_rebuild_required?(reason)
  end

  def self.merge_train_rebuild_required?(reason)
    text = reason.to_s
    text.match?(/\Amerge_train: base moved .* rebuild required/i) ||
      text.match?(/\Amerge_train: missing built base SHA; rebuild required/i)
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
      chunk: "landing_queue: paused landing because auto-merge hit an infrastructure blocker; resume landing after clearing it (#{reason.truncate(180)})"
    )
  rescue StandardError => e
    Rails.logger.warn("[LandingFailureHandler] failed to log landing pause for #{job.slug}: #{e.class}: #{e.message}")
  end

  def log_deferral!
    log_run = run || job.current_run
    return unless log_run

    message = if landing_start_blocker?
      "landing_queue: deferred landing because the landing workflow could not start yet (#{reason.truncate(180)})"
    elsif transient_blocker?
      "landing_queue: deferred landing after a transient failure; the Job keeps its approval and the queue will try again (#{reason.truncate(180)})"
    elsif merge_train_rebuild_required?
      "landing_queue: deferred landing because the merge-train validation is stale or incomplete; Syrus will rebuild the train"
    else
      "landing_queue: deferred landing because the rebase cap was reached; run a manual rebase or wait for the PR head/base to change before retrying"
    end

    JobLog.append!(
      run: log_run,
      kind: "system",
      chunk: message
    )
  rescue StandardError => e
    Rails.logger.warn("[LandingFailureHandler] failed to log landing deferral for #{job.slug}: #{e.class}: #{e.message}")
  end
end
