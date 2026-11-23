require "stringio"

class MainHealthChangedService
  include RepairContext

  FIX_MAIN_TITLE = Job::MAIN_BRANCH_REPAIR_TITLE
  MAX_RECOVERY_RETRIES = 10
  MAX_RECOVERY_SCAN = 1_000
  MAX_OPEN_FAILED_FIX_JOBS = 3
  # The cap stops a runaway: three repairs failing in a row. It is not a
  # permanent latch. Failed repair Jobs stay open until someone closes them, so
  # counting every one ever made the third failure stop automatic repair for
  # good -- three repairs that died on harness bugs (now fixed) left main broken
  # until a human closed them, while main moved on to commits none of them had
  # tried. Only repairs that failed recently count.
  FAILED_FIX_JOB_CAP_WINDOW = 6.hours
  REPAIR_CANCELLATION_COOLDOWN = 30.minutes
  MAX_SUMMARY_ATTACHMENT_BYTES = 256.kilobytes
  MAX_CI_ATTACHMENT_BYTES = 4.megabytes
  MAX_GRADER_ATTACHMENT_BYTES = 12.megabytes
  BLOCKING_FIX_JOB_STATES = %w[needs_triage triaging queued running coding implemented approved landing].freeze
  NON_PROGRESSING_FIX_JOB_STATES = %w[needs_triage triaging queued].freeze
  STUCK_REPAIR_ALERT_AFTER = 30.minutes

  def self.on_health_change!(repository)
    new(repository).on_health_change!
  end

  def self.recovered!(repository)
    new(repository).recovered!
  end

  SUPERSEDED_PREFLIGHT_CLOSURE = "superseded".freeze

  # A repair still in preflight diagnoses the commit it snapshotted. When main
  # advances before the repair starts implementing, that diagnosis is stale:
  # a pushed fix had a repair grading the old commit for an hour and reporting
  # failures main no longer had. Close it; if the new head is still broken,
  # the ordinary health flow opens a repair for that commit. A repair that has
  # begun implementing is left alone -- it may already be fixing the head.
  def self.supersede_stale_preflight_repairs!(repository, head_sha:)
    return if head_sha.blank?

    each_preflight_repair(repository) do |job, workflow|
      snapshot_sha = WorkflowSourceSnapshots.current_for(workflow)&.source_sha
      next if snapshot_sha.blank? || snapshot_sha == head_sha

      Rails.logger.info(
        "[MainHealthChangedService] #{repository.slug} superseding #{job.slug}: preflight graded " \
        "#{snapshot_sha.first(12)}, main is now #{head_sha.first(12)}"
      )
      job.cancel_active_runs_and_close!(SUPERSEDED_PREFLIGHT_CLOSURE)
    end
  end

  # Once main is healthy, a repair that has not started implementing has
  # nothing left to fix. A failed repair retried after another repair had
  # already been approved kept grading about 140 preflight graders against a
  # main that turned healthy a few minutes later; nothing closed it, because
  # the commit-based rule above can see the new head in its own snapshot.
  def self.supersede_unneeded_preflight_repairs!(repository)
    return unless repository.main_health == "healthy"

    each_preflight_repair(repository) do |job, _workflow|
      Rails.logger.info("[MainHealthChangedService] #{repository.slug} superseding #{job.slug}: main is healthy")
      job.cancel_active_runs_and_close!(SUPERSEDED_PREFLIGHT_CLOSURE)
    end
  end

  def self.each_preflight_repair(repository)
    repository.jobs.where.not(state: "closed").find_each do |job|
      next unless job.main_branch_repair?

      workflow = job.latest_workflow
      next unless workflow&.trigger_kind == "main_branch_repair" && (workflow.running? || workflow.queued?)
      next if repair_implementation_started?(workflow)

      yield job, workflow
    end
  end
  private_class_method :each_preflight_repair

  def self.repair_implementation_started?(workflow)
    workflow.steps.where(kind: "implement").joins(:runs).exists?
  end
  private_class_method :repair_implementation_started?

  def self.ensure_repair_job!(repository, force: false)
    new(repository).ensure_repair_job!(force: force)
  end

  def self.refresh_repair_context!(job)
    new(job.repository).refresh_repair_context!(job)
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
      if @repository.strict_breakage_policy?
        pause_landing!
      else
        resume_landing!
      end
      stamp_active_workflows!
      ensure_repair_job!
      emit_notification!
    elsif @repository.main_health_inconclusive?
      resume_landing!
      start_blocked_queued_workflows!
      emit_inconclusive_notification!
    elsif @repository.main_health == "healthy"
      self.class.supersede_unneeded_preflight_repairs!(@repository)
      self.class.recovered!(@repository) if @repository.landing_paused?
    end
  end

  def recovered!
    Rails.logger.info(
      "[MainHealthChangedService] #{@repository.slug} main has recovered; resuming landing"
    )
    resume_landing!
    start_blocked_queued_workflows!
    retried_count = retry_held_jobs!
    rebased_count = rebase_failing_ci_jobs!
    emit_recovery_notification!(retried_count, rebased_count)
  end

  def ensure_repair_job!(force: false)
    return unless @repository.main_branch_health_enabled?
    return unless @repository.main_branch_repair_enabled?
    return unless @repository.main_health_broken?
    if (job = blocking_fix_job)
      # Decide staleness BEFORE refreshing. refresh_repair_context! writes the
      # prompt back to the Job, which bumps updated_at to now, and
      # stuck_blocking_repair_job asks whether updated_at is at least
      # STUCK_REPAIR_ALERT_AFTER old. Refreshing first therefore reset the very
      # clock the check reads, so the alarm that escalates a wedged
      # main-branch repair could never fire: every health signal rearmed it.
      # A repair Job parked in triaging stayed invisible while main stayed
      # broken.
      stuck_job = stuck_blocking_repair_job
      refresh_repair_context!(job)
      surface_stuck_blocking_repair!(stuck_job) if stuck_job
      return
    end
    # A failed repair with a pending auto-retry is not over: the retry will
    # relaunch it. Spawning another repair meanwhile ran two at once, each with
    # a full preflight grader fan-out on the same main.
    if (job = retrying_fix_job)
      Rails.logger.info(
        "[MainHealthChangedService] #{@repository.slug} not spawning main repair job; " \
        "failed repair job #{job.slug} has a pending auto-retry"
      )
      return
    end
    if !force && (job = failed_fix_job_for_current_sha)
      Rails.logger.warn(
        "[MainHealthChangedService] #{@repository.slug} not spawning main repair job; " \
        "failed repair job #{job.slug} already covers #{checked_sha}"
      )
      return
    end
    if !force && (job = no_progress_fix_job_for_current_sha)
      Rails.logger.warn(
        "[MainHealthChangedService] #{@repository.slug} not spawning main repair job; " \
        "repair job #{job.slug} stopped without grader progress for #{checked_sha}"
      )
      return
    end
    if !force && (job = conclusive_no_change_fix_job_for_current_sha)
      Rails.logger.warn(
        "[MainHealthChangedService] #{@repository.slug} not spawning main repair job; " \
        "conclusive no-change repair #{job.slug} already covers #{checked_sha}"
      )
      return
    end
    return if !force && suppressed_by_recent_closed_repair?

    # The stale-SHA guard keeps AUTOMATIC repairs from firing on a health signal
    # for a commit main has already moved past. An explicit operator repair
    # (force: true) is an intentional override — the same override that skips the
    # settled-signals wait below — so it bypasses this guard too (and can't be
    # blocked when the live default-branch SHA is momentarily unfetchable).
    return unless force || repair_target_sha_current?

    unless force || repair_evidence_ready?
      Rails.logger.info(
        "[MainHealthChangedService] #{@repository.slug} not spawning main repair job; " \
        "waiting for a settled broken CI or grader signal for #{checked_sha}"
      )
      return
    end

    failed_count = capped_failed_fix_jobs.count
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
    # The landing validated the repair's merge result, and nothing after it.
    # When main has already moved past that commit, the live head is
    # ungraded: grade it instead of declaring it healthy and lifting the
    # pause on stale evidence (formal/SyrusModel/RepairLift.lean).
    landed_sha = job.landed_sha.presence
    if landed_sha && latest_default_branch_sha.present? && latest_default_branch_sha != landed_sha
      Rails.logger.warn(
        "[MainHealthChangedService] #{@repository.slug} repair job #{job.slug} landed #{landed_sha.first(12)}, " \
        "but main is already at #{latest_default_branch_sha.first(12)}; grading it before resuming landing"
      )
      PollMainBranchHealthJob.perform_later(@repository.id)
      return
    end
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
    eligible = @repository.main_branch_health_enabled? && @repository.main_branch_repair_enabled? && @repository.main_health_broken?
    snapshot = eligible ? repair_status_jobs_snapshot : { blocking: nil, failed_jobs: [], failed_count: 0 }
    blocking = snapshot.fetch(:blocking)
    failed_jobs = snapshot.fetch(:failed_jobs)
    failed_count = snapshot.fetch(:failed_count)
    failed_current = eligible ? failed_fix_job_for_current_sha : nil
    below_failed_cap = failed_count < MAX_OPEN_FAILED_FIX_JOBS
    evidence_ready = nil
    blocked_reason = if blocking
      blocking_fix_job_reason(blocking)
    elsif failed_current
      "failed_current_sha"
    elsif eligible && !below_failed_cap
      "failed_open_cap"
    elsif eligible
      evidence_ready = repair_evidence_ready?
      "waiting_for_health_signals" unless evidence_ready
    end
    can_request = eligible && blocking.blank? && failed_current.blank? && below_failed_cap

    {
      enabled: @repository.main_branch_repair_enabled?,
      max_open_failed_jobs: MAX_OPEN_FAILED_FIX_JOBS,
      failed_open_jobs_count: failed_count,
      failed_jobs: failed_jobs,
      blocked_reason: blocked_reason,
      blocking_job: blocking,
      can_request: can_request,
      can_spawn: can_request && (evidence_ready.nil? ? repair_evidence_ready? : evidence_ready)
    }
  end

  def stuck_blocking_repair_job(now: Time.current)
    return unless @repository.main_branch_health_enabled?
    return unless @repository.main_branch_repair_enabled?
    return unless @repository.main_health_broken?

    job = blocking_fix_job
    return unless job
    return unless job.state.in?(NON_PROGRESSING_FIX_JOB_STATES)
    return unless job.updated_at && job.updated_at <= STUCK_REPAIR_ALERT_AFTER.ago(now)

    job
  end

  private

  def pause_landing!
    @repository.update!(landing_paused: true) unless @repository.landing_paused?
  end

  def resume_landing!
    @repository.update!(landing_paused: false) if @repository.landing_paused?
  end

  def stamp_active_workflows!
    WorkUnit
      .includes(:workflow)
      .where(repository_id: @repository.id, state: WorkUnits::Ownership::ACTIVE_STATES)
      .find_each do |unit|
        workflow = unit.workflow
        next unless workflow&.state.in?(%w[queued running])

        # The artifact is unconditional: whether main was red while a workflow
        # ran is useful context regardless of whether it gates anything. Only
        # the block itself is policy-dependent.
        workflow.set_artifact!("main_broken", true)
        record_queued_work_unit_main_health_block!(workflow)
      end
  end

  # One predicate decides whether main health holds work at the start line,
  # and StepDispatcher owns it.
  #
  # This used to stamp the block whenever main went broken, with no reference
  # to the repository's breakage policy, while the dispatcher requires a
  # strict policy, main_branch_repair_blocks_work?, AND a paused landing
  # queue. Under `isolate_unrelated_failures` the two disagreed: the
  # dispatcher would never block the workflow, and this stamped the block
  # anyway. Nothing then re-admitted it, so workflows sat `blocked` for as
  # long as main stayed red -- six of them for over seven days, not one
  # having started a single run, while the policy said health must not gate
  # anything. Asking the dispatcher makes the disagreement impossible.
  def record_queued_work_unit_main_health_block!(workflow)
    return unless workflow.queued?
    return if workflow.steps.joins(:runs).exists?
    return unless StepDispatcher.main_health_blocking?(workflow)

    WorkUnits::WorkflowBlockProjection.record!(
      workflow,
      start_blocked_reason: StepDispatcher::MAIN_HEALTH_BLOCK_REASON,
      blocked_until: StepDispatcher::START_BLOCKED_BACKOFF.from_now,
      details: {
        "repository_id" => @repository.id,
        "repository_slug" => @repository.slug,
        "main_health_state" => "broken"
      }
    )

    # Even a legitimate block has to be able to clear itself. Without a
    # recheck this waited on a later health transition to call
    # start_blocked_queued_workflows!, which never comes while main stays
    # broken.
    WorkflowPhaseAdmissionJob.enqueue_once(
      workflow.id,
      wait: StepDispatcher::START_BLOCKED_BACKOFF,
      priority: workflow.solid_queue_priority
    )
  end

  def start_blocked_queued_workflows!
    # Queued workflows with no runs were blocked at the StepDispatcher gate
    # when main was broken. Call start_workflow again now that main is healthy.
    WorkUnit
      .includes(:workflow)
      .where(repository_id: @repository.id, state: "blocked", blocked_reason: "main_branch_health")
      .find_each do |unit|
        workflow = unit.workflow
        next unless workflow&.queued?
        next if workflow.steps.joins(:runs).exists?

        WorkUnits::Launcher.start!(workflow)
      end
  end

  def retry_held_jobs!
    retried = 0
    attempted_job_ids = {}

    recent_failed_ids = Workflow
      .joins(:job)
      .where(jobs: { repository_id: @repository.id })
      .where.not(jobs: { state: "closed" })
      .where(state: "failed")
      .order(id: :desc)
      .limit(MAX_RECOVERY_SCAN)
      .pluck(:id)

    return retried if recent_failed_ids.empty?

    candidates = Workflow
      .where(id: recent_failed_ids)
      .joins(:workflow_artifact_values)
      .where(workflow_artifact_values: { key: "main_broken", value: true })

    candidate_ids_and_job_ids = candidates.pluck(:id, :job_id)
    return retried if candidate_ids_and_job_ids.empty?

    latest_workflow_ids = Workflow
      .where(job_id: candidate_ids_and_job_ids.map(&:last).uniq)
      .group(:job_id)
      .maximum(:id)

    Workflow
      .where(id: candidate_ids_and_job_ids.map(&:first))
      .includes(:job)
      .find_each(order: :desc) do |workflow|
        break if retried >= MAX_RECOVERY_RETRIES
        next if attempted_job_ids[workflow.job_id]
        next unless recoverable_main_broken_workflow?(workflow, latest_workflow_ids: latest_workflow_ids)

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

  def recoverable_main_broken_workflow?(workflow, latest_workflow_ids:)
    return false unless workflow.artifact("main_broken")
    return false if workflow.job.implemented? || workflow.job.approved? || workflow.job.landing?
    return false unless latest_workflow_ids[workflow.job_id] == workflow.id

    true
  end

  # PRs left with pr_checks_state == "failing" while main was broken never
  # got a fresh CI run pointed at the healthy base — GitHub doesn't silently
  # re-run stale check results just because the base branch moved. A cheap
  # mechanical rebase (auto_rebase escalates to an agent only on real
  # conflict) gives GitHub a new SHA to check; the next poll only fires
  # ci_failure if the PR's own diff is genuinely still broken. Deliberately
  # queries live pr_checks_state instead of a persisted "deferred" marker so
  # it sweeps up every red-CI Job regardless of which guard skipped its
  # repair (the main-health ci_failure gate, an attempt cap that was counting
  # transient failures, or a race window), with no bookkeeping to fall out of
  # sync.
  #
  # Bypassing the attempt cap is the point: the cap is time-and-count based
  # and main recovering is new information, so a Job that had exhausted its
  # retries deserves another against the healthy base. That argument only
  # holds where a retry could plausibly differ. It does not hold for a
  # deterministic failure, and sweeping those produced a Job that rebased,
  # refused to publish, and got swept in again every few minutes for two days
  # -- each pass burning an agent run on a branch that could never be
  # published, because the thing blocking it was a missing handoff fix rather
  # than anything about the base. `permanently_blocked?` is the narrow
  # exception: still bypass the cooldown, never re-dispatch work whose
  # outcome is already decided.
  def rebase_failing_ci_jobs!
    rebased = 0

    @repository.jobs.open_threads.where(pr_checks_state: "failing").find_each do |job|
      break if rebased >= MAX_RECOVERY_RETRIES
      next if job.branch_name.blank?
      next if RebaseWorkflowSelector.active_for_stack?(job)
      next if RebaseWorkflowSelector.active_merge_train_for_stack?(job)
      next if permanently_blocked_from_rebase?(job)

      workflow = RebaseWorkflowSelector.instantiate(
        job: job,
        artifacts: { "repair_reason" => "main branch recovered; PR checks were failing against the broken base" }
      )
      result = WorkUnits::Launcher.start!(workflow)
      rebased += 1 if result.started?
    rescue WorkUnits::Launcher::LockConflict => e
      Rails.logger.info(
        "[MainHealthChangedService] #{@repository.slug} skipped recovery rebase for #{job.slug}; " \
        "#{e.lock_key} is already owned by #{e.work_unit&.slug}"
      )
    rescue StandardError => e
      Rails.logger.error(
        "[MainHealthChangedService] #{@repository.slug} failed to dispatch recovery rebase for #{job.slug}: " \
        "#{e.class}: #{e.message}"
      )
    end

    rebased
  end

  def permanently_blocked_from_rebase?(job)
    return false unless RebaseAttemptGuard.permanently_blocked?(job)

    Rails.logger.info(
      "[MainHealthChangedService] #{@repository.slug} skipped recovery rebase for #{job.slug}; " \
      "its last rebase failed non-retryably and re-dispatching cannot change that"
    )
    true
  end

  def spawn_fix_job!
    user = @repository.user
    return unless user

    Job.transaction do
      job = create_fix_job(user)
      next blocking_fix_job unless job

      attach_repair_context!(job)
      job.advance_after_triage! if job.may_advance_after_triage?
      job
    end
  end

  def create_fix_job(user)
    user.jobs.create!(
      repository: @repository,
      kind: "direct",
      system_kind: Job::SYSTEM_KIND_MAIN_BRANCH_REPAIR,
      issue_number: nil,
      issue_title: FIX_MAIN_TITLE,
      issue_body: fix_job_prompt,
      agent_provider: @repository.user&.agent_provider,
      priority: repair_job_priority
    )
  rescue ActiveRecord::RecordNotUnique => e
    # Two concurrent triggers (e.g. a health poll and an inline repair
    # check from a Jobs#show request) can both pass every guard above and
    # race to create the repair Job; the slug's unique index is the last
    # line of defense. Reuse whichever process won instead of 500ing the
    # caller. Scoped to just this create! call so a RecordNotUnique from a
    # deeper side effect (e.g. WorkUnitLock creation inside
    # advance_after_triage!) is never mistaken for this slug race.
    Rails.logger.warn(
      "[MainHealthChangedService] #{@repository.slug} main repair job creation raced with " \
      "another process; reusing the job it already created (#{e.message})"
    )
    nil
  end

  def repair_job_priority
    @repository.main_branch_repair_blocks_work? ? "urgent" : "high"
  end

  def suppressed_by_recent_closed_repair?
    return false if @repository.strict_breakage_policy?

    repair_jobs
      .where(state: "closed")
      .where.not(closure_reason: %w[pr_merged external_pr_merged])
      .where(updated_at: REPAIR_CANCELLATION_COOLDOWN.ago..)
      .exists?
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

  def capped_failed_fix_jobs(now: Time.current)
    open_failed_fix_jobs.where("COALESCE(jobs.finished_at, jobs.updated_at) >= ?", now - FAILED_FIX_JOB_CAP_WINDOW)
  end

  def failed_fix_job_for_current_sha
    sha = checked_sha
    return if sha == "unknown"

    open_failed_fix_jobs
      .where("jobs.issue_body LIKE ?", "%Commit: #{Job.sanitize_sql_like(sha)}%")
      .order(updated_at: :desc, id: :desc)
      .first
  end

  def no_progress_fix_job_for_current_sha
    sha = checked_sha
    return if sha == "unknown"

    repair_jobs
      .where(needs_attention_reason: GraderLoopProgress::NO_PROGRESS_REASON)
      .where("jobs.issue_body LIKE ?", "%Commit: #{Job.sanitize_sql_like(sha)}%")
      .order(updated_at: :desc, id: :desc)
      .first
  end

  def conclusive_no_change_fix_job_for_current_sha
    sha = checked_sha
    return if sha == "unknown"

    candidates = repair_jobs
      .where(state: "closed", closure_reason: "preflight_passed")
      .where("jobs.issue_body LIKE ?", "%Commit: #{Job.sanitize_sql_like(sha)}%")

    if @repository.ci_health_broken?
      fingerprint = repair_evidence_fingerprint(sha, signal: :ci)
      candidates = candidates.where("jobs.issue_body LIKE ?", "%CI evidence fingerprint: #{fingerprint}%")
    end
    if @repository.grader_health_broken?
      fingerprint = repair_evidence_fingerprint(sha, signal: :grader)
      candidates = candidates.where("jobs.issue_body LIKE ?", "%Grader evidence fingerprint: #{fingerprint}%")
    end

    candidates.order(updated_at: :desc, id: :desc).first
  end

  def recent_open_failed_fix_jobs
    open_failed_fix_jobs.order(updated_at: :desc, id: :desc).limit(MAX_OPEN_FAILED_FIX_JOBS)
  end

  def repair_status_jobs_snapshot
    states = (BLOCKING_FIX_JOB_STATES + [ "failed" ]).uniq
    candidates = repair_jobs
      .where(state: states)
      .order(updated_at: :desc, id: :desc)
      .limit(50)
      .to_a
    capped = capped_failed_fix_jobs.order(updated_at: :desc, id: :desc).limit(MAX_OPEN_FAILED_FIX_JOBS).to_a

    {
      blocking: candidates.find { |job| BLOCKING_FIX_JOB_STATES.include?(job.state) },
      failed_jobs: capped,
      failed_count: capped_failed_fix_jobs.count
    }
  end

  def blocking_fix_job
    repair_jobs
      .where(state: BLOCKING_FIX_JOB_STATES)
      .order(updated_at: :desc, id: :desc)
      .first
  end

  def retrying_fix_job
    open_failed_fix_jobs
      .where(id: AutoRetryAttempt.pending.select(:job_id))
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

  # Takes the Job that stuck_blocking_repair_job already identified, read before
  # the context refresh moved its updated_at.
  def surface_stuck_blocking_repair!(job)
    Rails.logger.warn(
      "[MainHealthChangedService] #{@repository.slug} main remains broken, but repair job #{job.slug} " \
      "has been #{job.state} since #{job.updated_at&.iso8601}; surfacing it through stuck-item reconciliation"
    )
    WorkEngine::Reconciler.request(source: "#{self.class.name}#ensure_repair_job!", job: job)
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

  # CI and grader signals are polled independently and update different parts
  # of the same health row. Fingerprinting them independently means a stale CI
  # reassertion remains covered even if the clean preflight has already reset
  # the grader half (and vice versa), while genuinely changed evidence for the
  # currently broken signal remains eligible immediately.
  def repair_evidence_fingerprint(sha, signal:)
    checks = health_checks_for(sha)
    evidence = if signal == :ci
      checks.select { |check| check.ci_health == "broken" }
        .flat_map { |check| Array(check.ci_failed_checks) }
        .map { |entry| canonical_repair_evidence(entry) }
        .sort_by { |entry| JSON.generate(entry) }
    else
      checks.select { |check| check.grader_health == "broken" }
        .map do |check|
          {
            "workflow_id" => check.workflow_id,
            "failed_names" => Array(check.grader_failed_names).map(&:to_s).uniq.sort
          }
        end
        .sort_by { |entry| JSON.generate(entry) }
    end

    Digest::SHA256.hexdigest(JSON.generate(evidence))
  end

  def canonical_repair_evidence(value)
    if value.is_a?(Hash)
      return value.keys.sort_by(&:to_s).to_h { |key| [ key.to_s, canonical_repair_evidence(value[key]) ] }
    end
    return value.map { |entry| canonical_repair_evidence(entry) } if value.is_a?(Array)

    value
  end

  def repair_evidence_ready?
    sha = checked_sha
    return false if sha == "unknown"

    settled_broken_ci_signal?(sha) || settled_broken_grader_signal?(sha)
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

  def settled_broken_ci_signal?(sha)
    @repository.last_ci_evaluated_sha == sha &&
      @repository.ci_health_broken? &&
      MainBranchHealthCheck.broken_ci_result_exists?(repository: @repository, sha: sha)
  end

  def settled_broken_grader_signal?(sha)
    @repository.grader_health_broken? &&
      MainBranchHealthCheck.broken_grader_result_exists?(repository: @repository, sha: sha)
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
      repository: @repository,
      body: body,
      dedupe_key: main_broken_notification_dedupe_key(sha, signals)
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
      repository: @repository,
      body: "Main branch health is inconclusive on #{@repository.slug}: graders need operator review at #{sha_short}."
    )
  end

  def emit_recovery_notification!(retried_count, rebased_count = 0)
    user = @repository.user
    return unless user

    body = "Main branch recovered on #{@repository.slug}."
    if retried_count > 0
      noun = retried_count == 1 ? "job" : "jobs"
      body += " #{retried_count} #{noun} queued for auto-retry."
    end
    if rebased_count > 0
      noun = rebased_count == 1 ? "PR" : "PRs"
      body += " #{rebased_count} #{noun} rebased for a fresh CI run."
    end

    NotificationService.create_for(
      user: user,
      kind: "main_recovered",
      repository: @repository,
      body: body
    )
  end

  def broken_signals
    signals = []
    signals << "CI" if @repository.ci_health_broken?
    signals << "graders" if @repository.grader_health_broken?
    signals
  end

  def main_broken_notification_dedupe_key(sha, signals)
    "main_broken:sha=#{sha}:signals=#{signals.sort.join(',')}"
  end
end
