class MainHealthChangedService
  FIX_MAIN_TITLE = "Fix broken main branch".freeze

  def self.on_health_change!(repository)
    new(repository).on_health_change!
  end

  def self.recovered!(repository)
    # Stub: full recovery logic (resume landing, unblock queued workflows,
    # emit recovery notification) will be implemented by the recovery Job
    # in EPIC-161.
  end

  def initialize(repository)
    @repository = repository
  end

  def on_health_change!
    Rails.logger.warn(
      "[MainHealthChangedService] #{@repository.slug} main_health=#{@repository.main_health} " \
      "ci_health=#{@repository.ci_health} grader_health=#{@repository.grader_health}"
    )

    if @repository.main_health_broken?
      pause_landing!
      stamp_active_workflows!
      spawn_fix_job!
      emit_notification!
    elsif @repository.main_health == "healthy"
      self.class.recovered!(@repository)
    end
  end

  private

  def pause_landing!
    @repository.update!(landing_paused: true) unless @repository.landing_paused?
  end

  def stamp_active_workflows!
    Workflow.joins(:job)
            .where(jobs: { repository_id: @repository.id })
            .where(state: %w[queued running])
            .find_each do |workflow|
      workflow.set_artifact!("main_broken", true)
    end
  end

  def spawn_fix_job!
    return if open_fix_job_exists?

    user = @repository.user
    return unless user

    job = user.jobs.create!(
      repository: @repository,
      kind: "direct",
      issue_number: nil,
      issue_title: FIX_MAIN_TITLE,
      issue_body: fix_job_prompt,
      agent_provider: @repository.effective_agent_provider,
      priority: "high"
    )
    job.advance_after_triage! if job.may_advance_after_triage?
  end

  def open_fix_job_exists?
    @repository.jobs
               .where(kind: "direct", issue_title: FIX_MAIN_TITLE)
               .where.not(state: "closed")
               .exists?
  end

  def fix_job_prompt
    "Main branch health is broken. `ci_health`: #{@repository.ci_health}, " \
    "`grader_health`: #{@repository.grader_health}. " \
    "Identify the root cause from recent CI failures and/or grader output on the default branch, " \
    "and push a minimal fix to restore a green main."
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

  def broken_signals
    signals = []
    signals << "CI" if @repository.ci_health_broken?
    signals << "graders" if @repository.grader_health_broken?
    signals
  end
end
