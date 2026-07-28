require "stringio"

class MainHealthChangedService
  include RepairContext

  FIX_MAIN_TITLE = Job::MAIN_BRANCH_REPAIR_TITLE
  MAX_RECOVERY_RETRIES = 10
  MAX_OPEN_FAILED_FIX_JOBS = 3
  MAX_SUMMARY_ATTACHMENT_BYTES = 256.kilobytes
  MAX_CI_ATTACHMENT_BYTES = 4.megabytes
  MAX_GRADER_ATTACHMENT_BYTES = 12.megabytes
  BLOCKING_FIX_JOB_STATES = %w[needs_triage triaging queued running coding implemented approved landing].freeze

  def self.on_health_change!(repository)
    new(repository).on_health_change!
  end

  def self.recovered!(repository)
    new(repository).recovered!
  end

  def self.ensure_repair_job!(repository, force: false)
    new(repository).ensure_repair_job!(force: force)
  end

  def self.repair_landed!(repository, job:)
    new(repository).repair_landed!(job: job)
  end

  def self.fix_main_job?(job)
    job.main_branch_repair?
  end

  def initialize(repository)
    @repository = repository
  end

  def on_health_change!
    unless @repository.main_branch_health_enabled?
      Rails.logger.info("[MainHealthChangedService] #{@repository.slug} main health disabled; ignoring health change")
      return
    end

    Rails.logger.warn(
      "[MainHealthChangedService] #{@repository.slug} main_health=#{@repository.main_health} " \
      "ci_health=#{@repository.ci_health} grader_health=#{@repository.grader_health}"
    )

    if @repository.main_health_broken?
      pause_landing!
      stamp_active_workflows!
      ensure_repair_job!
      emit_notification!
    elsif @repository.main_health_inconclusive?
      pause_landing!
      emit_inconclusive_notification!
    elsif @repository.main_health == "healthy" && @repository.landing_paused?
      self.class.recovered!(@repository)
    end
  end

  def recovered!
    Rails.logger.info(
      "[MainHealthChangedService] #{@repository.slug} main has recovered; resuming landing"
    )
    resume_landing!
    start_blocked_queued_workflows!
    retried_count = retry_held_jobs!
    emit_recovery_notification!(retried_count)
  end

  def ensure_repair_job!(force: false)
    return unless @repository.main_branch_health_enabled?
    return unless @repository.main_branch_repair_enabled?
    return unless @repository.main_health_broken?
    return if blocking_fix_job

    # The stale-SHA guard keeps AUTOMATIC repairs from firing on a health signal
    # for a commit main has already moved past. An explicit operator repair
    # (force: true) is an intentional override — the same override that skips the
    # settled-signals wait below — so it bypasses this guard too (and can't be
    # blocked when the live default-branch SHA is momentarily unfetchable).
    return unless force || repair_target_sha_current?

    unless force || repair_signals_ready?
      Rails.logger.info(
        "[MainHealthChangedService] #{@repository.slug} not spawning main repair job; " \
        "waiting for settled CI and grader signals for #{checked_sha}"
      )
      return
    end

    failed_count = open_failed_fix_jobs.count
    if failed_count >= MAX_OPEN_FAILED_FIX_JOBS
      Rails.logger.warn(
        "[MainHealthChangedService] #{@repository.slug} not spawning main repair job; " \
        "#{failed_count}/#{MAX_OPEN_FAILED_FIX_JOBS} failed repair jobs remain open"
      )
      return
    end

    spawn_fix_job!
  end

  def repair_landed!(job:)
    return unless @repository.main_branch_health_enabled?

    sha = latest_default_branch_sha.presence || job.head_sha.presence || checked_sha
    unless sha.present? && sha != "unknown"
      Rails.logger.warn(
        "[MainHealthChangedService] #{@repository.slug} repair job #{job.slug} landed, " \
        "but current default branch SHA could not be determined"
      )
      return
    end

    ci_health = @repository.ci_health_not_configured? ? "not_configured" : "healthy"
    @repository.update!(
      last_health_checked_sha: sha,
      last_ci_evaluated_sha: sha,
      last_graded_sha: sha,
      ci_health: ci_health,
      grader_health: "healthy"
    )

    MainBranchHealthCheck.record_ci_poll(
      repository: @repository,
      sha: sha,
      ci_health: ci_health,
      ci_failed_checks: []
    )
    MainBranchHealthCheck.record_grader_workflow(
      repository: @repository,
      workflow: job.latest_workflow,
      sha: sha,
      grader_health: "healthy",
      grader_failed_names: []
    )

    recovered!
  end

  def repair_status
    blocking = blocking_fix_job
    failed_jobs = recent_open_failed_fix_jobs.to_a
    failed_count = open_failed_fix_jobs.count
    eligible = @repository.main_branch_health_enabled? && @repository.main_branch_repair_enabled? && @repository.main_health_broken?
    below_failed_cap = failed_count < MAX_OPEN_FAILED_FIX_JOBS
    blocked_reason = if blocking
      blocking_fix_job_reason(blocking)
    elsif eligible && !repair_signals_ready?
      "waiting_for_health_signals"
    elsif eligible && !below_failed_cap
      "failed_open_cap"
    end
    can_request = eligible && blocking.blank? && below_failed_cap

    {
      enabled: @repository.main_branch_repair_enabled?,
      max_open_failed_jobs: MAX_OPEN_FAILED_FIX_JOBS,
      failed_open_jobs_count: failed_count,
      failed_jobs: failed_jobs,
      blocked_reason: blocked_reason,
      blocking_job: blocking,
      can_request: can_request,
      can_spawn: can_request && repair_signals_ready?
    }
  end

  private

  def pause_landing!
    @repository.update!(landing_paused: true) unless @repository.landing_paused?
  end

  def resume_landing!
    @repository.update!(landing_paused: false) if @repository.landing_paused?
  end

  def stamp_active_workflows!
    Workflow.joins(:job)
            .where(jobs: { repository_id: @repository.id })
            .where(state: %w[queued running])
            .find_each do |workflow|
      workflow.set_artifact!("main_broken", true)
    end
  end

  def start_blocked_queued_workflows!
    # Queued workflows with no runs were blocked at the StepDispatcher gate
    # when main was broken. Call start_workflow again now that main is healthy.
    Workflow
      .joins(:job)
      .where(jobs: { repository_id: @repository.id })
      .where(state: "queued")
      .where.not(id: Workflow.joins(steps: :runs).select("workflows.id"))
      .find_each do |workflow|
        StepDispatcher.start_workflow(workflow)
      end
  end

  def retry_held_jobs!
    retried = 0
    attempted_job_ids = {}

    Workflow
      .joins(:job)
      .where(jobs: { repository_id: @repository.id })
      .where.not(jobs: { state: "closed" })
      .where(state: "failed")
      .includes(:job)
      .order(id: :desc)
      .each do |workflow|
        break if retried >= MAX_RECOVERY_RETRIES
        next if attempted_job_ids[workflow.job_id]
        next unless recoverable_main_broken_workflow?(workflow)

        attempted_job_ids[workflow.job_id] = true
        result = RetryWorkflowEnqueuer.call(
          job: workflow.job,
          provider_validation: :none,
          automatic: true
        )
        retried += 1 if result.success?
      end
    retried
  end

  def recoverable_main_broken_workflow?(workflow)
    return false unless workflow.artifact("main_broken")
    return false if workflow.job.implemented? || workflow.job.approved? || workflow.job.landing?
    return false if newer_workflow_exists?(workflow)

    true
  end

  def newer_workflow_exists?(workflow)
    workflow
      .job
      .workflows
      .where("id > ?", workflow.id)
      .exists?
  end

  def spawn_fix_job!
    user = @repository.user
    return unless user

    job = user.jobs.create!(
      repository: @repository,
      kind: "direct",
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
      issue_number: nil,
      issue_title: FIX_MAIN_TITLE,
      issue_body: fix_job_prompt,
      agent_provider: @repository.effective_agent_provider,
      priority: "urgent"
    )
    attach_repair_context!(job)
    job.advance_after_triage! if job.may_advance_after_triage?
    job
  end

  def repair_jobs
    @repository.jobs
               .where(kind: "direct")
               .where(
                 "jobs.system_kind = :system_kind OR (jobs.system_kind IS NULL AND jobs.issue_title = :title)",
                 system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
                 title: FIX_MAIN_TITLE
               )
  end

  def open_failed_fix_jobs
    repair_jobs.where(state: "failed")
  end

  def recent_open_failed_fix_jobs
    open_failed_fix_jobs.order(updated_at: :desc, id: :desc).limit(MAX_OPEN_FAILED_FIX_JOBS)
  end

  def blocking_fix_job
    repair_jobs
      .where(state: BLOCKING_FIX_JOB_STATES)
      .order(updated_at: :desc, id: :desc)
      .first
  end

  def blocking_fix_job_reason(job)
    if job.needs_triage? || job.triaging? || job.queued? || job.running? || job.coding?
      "active"
    elsif job.approved? || job.landing?
      "landing"
    else
      "waiting"
    end
  end

  def checked_sha
    @repository.last_health_checked_sha.to_s.presence || "unknown"
  end

  def repair_attachment_prefix(sha)
    "main-health-#{short_sha(sha)}"
  end

  def short_sha(sha)
    value = sha.to_s.presence || "unknown"
    value.length > 12 ? value[0, 12] : value
  end

  def health_checks_for(sha)
    return [] if sha == "unknown"

    MainBranchHealthCheck
      .where(repository: @repository, sha: sha)
      .includes(:workflow)
      .recent
      .limit(20)
      .to_a
  end

  def repair_signals_ready?
    sha = checked_sha
    return false if sha == "unknown"

    settled_ci_signal?(sha) && settled_grader_signal?(sha)
  end

  def repair_target_sha_current?
    sha = checked_sha
    return false if sha == "unknown"

    live_sha = latest_default_branch_sha
    if live_sha == sha
      true
    else
      Rails.logger.info(
        "[MainHealthChangedService] #{@repository.slug} not spawning main repair job; " \
        "health target #{sha} is stale because #{@repository.default_branch} is now #{live_sha || 'unknown'}"
      )
      PollMainBranchHealthJob.perform_later(@repository.id)
      false
    end
  rescue StandardError => e
    Rails.logger.warn(
      "[MainHealthChangedService] #{@repository.slug} could not verify current default branch " \
      "before spawning a repair job: #{e.class}: #{e.message}"
    )
    false
  end

  def latest_default_branch_sha
    return @latest_default_branch_sha if defined?(@latest_default_branch_sha)

    @latest_default_branch_sha = if @repository.user
      GithubClient
        .for(repository: @repository, user: @repository.user)
        .branch_head_sha(@repository.slug, @repository.default_branch)
        .to_s
        .presence
    end
  end

  def settled_ci_signal?(sha)
    @repository.last_ci_evaluated_sha == sha &&
      @repository.ci_health.in?(MainBranchHealthCheck::SETTLED_CI_HEALTH) &&
      MainBranchHealthCheck.settled_ci_result_exists?(repository: @repository, sha: sha)
  end

  def settled_grader_signal?(sha)
    @repository.grader_health.in?(MainBranchHealthCheck::SETTLED_GRADER_HEALTH) &&
      MainBranchHealthCheck.settled_grader_result_exists?(repository: @repository, sha: sha)
  end

  def truncate_attachment_body(body, max_bytes)
    text = body.to_s
    return text if text.bytesize <= max_bytes

    notice = "\n\n... [truncated #{text.bytesize - max_bytes} bytes] ...\n"
    text.safe_byteslice(0, max_bytes - notice.bytesize) + notice
  end

  def failed_check_name(failed_check)
    failed_check_value(failed_check, "name") || "unknown check"
  end

  def failed_check_url(failed_check)
    failed_check_value(failed_check, "url") || failed_check_value(failed_check, "html_url")
  end

  def failed_check_value(failed_check, key)
    failed_check[key].presence || failed_check[key.to_sym].presence
  end

  def emit_notification!
    user = @repository.user
    return unless user

    signals = broken_signals
    sha = @repository.last_health_checked_sha.presence || "unknown"
    sha_short = sha.length > 8 ? sha[0, 8] : sha

    body = "Main branch broken on #{@repository.slug}: " \
           "#{signals.join(' and ')} failed at #{sha_short}."

    NotificationService.create_for(
      user: user,
      kind: "main_broken",
      body: body
    )
  end

  def emit_inconclusive_notification!
    user = @repository.user
    return unless user

    sha = @repository.last_health_checked_sha.presence || "unknown"
    sha_short = sha.length > 8 ? sha[0, 8] : sha

    NotificationService.create_for(
      user: user,
      kind: "main_inconclusive",
      body: "Main branch health is inconclusive on #{@repository.slug}: graders need operator review at #{sha_short}."
    )
  end

  def emit_recovery_notification!(retried_count)
    user = @repository.user
    return unless user

    body = "Main branch recovered on #{@repository.slug}."
    if retried_count > 0
      noun = retried_count == 1 ? "job" : "jobs"
      body += " #{retried_count} #{noun} queued for auto-retry."
    end

    NotificationService.create_for(
      user: user,
      kind: "main_recovered",
      body: body
    )
  end

  def broken_signals
    signals = []
    signals << "CI" if @repository.ci_health_broken?
    signals << "graders" if @repository.grader_health_broken?
    signals
  end
end
