class ScheduledTaskFire
  Result = Data.define(:job, :skipped, :reason) do
    def fired? = !skipped
  end

  attr_reader :now

  def initialize(task, now: Time.current, require_due: false)
    @task = task
    @now = now
    @require_due = require_due
  end

  # Spawn a cron Job for this fire (or skip per pr_pileup_policy).
  # Stamps last_fired_at unconditionally so the next due-check uses
  # this tick as its baseline. Guards the current fire window under a
  # row lock so concurrent pollers/manual fires cannot duplicate Jobs.
  # Marks one_shot tasks as `fired` after they spawn their Job. Honors
  # pr_pileup_policy:
  #
  #   skip     — don't fire if a prior PR is still open
  #   pile     — fire regardless (lets PRs stack)
  #   replace  — close prior open PRs from this task before firing
  def call
    @task.with_lock do
      @task.reload
      return Result.new(job: nil, skipped: true, reason: "not_fireable") if @task.archived? || @task.fired?
      return Result.new(job: nil, skipped: true, reason: "not_due") if @require_due && !@task.due?(now: @now)

      manual = !@require_due
      window_start = @task.fire_window_start(now: @now, manual: manual)
      return Result.new(job: nil, skipped: true, reason: "not_due") if window_start.blank?
      if @task.fired_in_window?(window_start)
        return Result.new(job: nil, skipped: true, reason: "already_fired_window")
      end

      policy = PrPileupPolicies.for(@task.pr_pileup_policy).new(@task, fire_service: self)
      if (result = policy.check_pileup)
        return result
      end

      job = @task.skill_task? ? fire_skill_job! : fire_freeform_job!

      @task.record_fire!(at: @now)
      @task.mark_fired_one_shot! if @task.one_shot?

      Result.new(job: job, skipped: false, reason: nil)
    end
  end

  private

  # Job#after_create_commit only auto-instantiates the Initial workflow
  # for issue Jobs. Cron Jobs need explicit instantiation here so the
  # pre-rendered prompt rides through to the first Run; Steps::Implement
  # skips its GitHub round-trip when run.prompt is already set.
  def fire_freeform_job!
    rendered_prompt = Prompts::ScheduledTask.new(scheduled_task: @task, fired_at: @now).to_s

    job = Job.create!(
      user: @task.user,
      repository: @task.repository,
      kind: "cron",
      scheduled_task: @task,
      issue_title: "Scheduled task: #{@task.name}",
      issue_body: rendered_prompt,
      issue_number: nil
    )
    job.advance_after_triage! if job.may_advance_after_triage?

    workflow = WorkUnits::Launcher.instantiate(kind: "initial", job: job)
    StepDispatcher.start_workflow(workflow, prompt: rendered_prompt)
    job
  end

  # Mirrors fire_freeform_job! but dispatches Workflows::Skill instead
  # of pre-rendering a Prompts::ScheduledTask prompt. The actual
  # instructions come from Skills::Renderer/Prompts::Skill inside
  # Steps::RunSkill (the same rendering path SkillJobs::Creator's direct
  # skill Jobs use) — prompt: nil here lets that step resolve, validate,
  # and render on its own turn, so a skill that changed (or vanished)
  # since this task was last saved surfaces as a normal Run failure
  # instead of wedging the poller. issue_body is a best-effort preview
  # for the Job list/synthetic_issue; a failure to pre-render it never
  # blocks the fire.
  def fire_skill_job!
    args = @task.skill_args.presence || {}

    job = Job.create!(
      user: @task.user,
      repository: @task.repository,
      kind: "cron",
      scheduled_task: @task,
      skill_name: @task.skill_name,
      skill_args: args,
      issue_title: "Scheduled task: #{@task.name}",
      issue_body: skill_issue_body_preview(args),
      issue_number: nil
    )
    job.advance_after_triage! if job.may_advance_after_triage?

    workflow = WorkUnits::Launcher.instantiate(kind: "skill", job: job, artifacts: job.skill_workflow_artifacts)
    StepDispatcher.start_workflow(workflow, prompt: nil)
    job
  end

  def skill_issue_body_preview(args)
    resolution = Skills.for(repository: @task.repository, name: @task.skill_name, user: @task.user)
    Skills::Renderer.render(resolution.definition, args)
  rescue Skills::NotFoundError, ArgumentError, Skills::SkillMarkdown::ParseError, Skills::ParameterSchema::ParseError
    "Skill: #{@task.skill_name}"
  end

  public

  def close_prior_open_prs
    @task.open_pr_jobs.find_each do |old_job|
      Rails.logger.info("[ScheduledTaskFire] task ##{@task.id} closing prior PR ##{old_job.pr_number} (#{old_job.slug}) per replace policy")
      begin
        GithubClient.for(repository: @task.repository, user: @task.user).close_pull_request(@task.repository.slug, old_job.pr_number)
      rescue StandardError => e
        Rails.logger.warn("[ScheduledTaskFire] failed to close PR ##{old_job.pr_number}: #{e.class}: #{e.message}")
      end
      old_job.close_with_reason!("replaced_by_scheduled_task")
    end
  end
end
