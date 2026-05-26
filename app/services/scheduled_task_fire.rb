class ScheduledTaskFire
  Result = Data.define(:job, :skipped, :reason) do
    def fired? = !skipped
  end

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

      case @task.pr_pileup_policy
      when "skip"
        if @task.has_open_pr?
          @task.record_fire!(at: @now)
          return Result.new(job: nil, skipped: true, reason: "prior_pr_open")
        end
      when "replace"
        close_prior_open_prs
      when "pile"
        # fall through
      end

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
      job.advance_after_triage!
      # Job#after_create_commit only auto-instantiates the Initial
      # workflow for issue Jobs. Cron Jobs need explicit instantiation
      # here so the pre-rendered prompt rides through to the first
      # Run; Steps::Implement skips its GitHub round-trip when
      # run.prompt is already set.
      workflow = Workflows::Initial.instantiate(job: job)
      StepDispatcher.start_workflow(workflow, prompt: rendered_prompt)

      @task.record_fire!(at: @now)
      @task.mark_fired_one_shot! if @task.one_shot?

      Result.new(job: job, skipped: false, reason: nil)
    end
  end

  private

  def close_prior_open_prs
    @task.open_pr_jobs.find_each do |old_job|
      Rails.logger.info("[ScheduledTaskFire] task ##{@task.id} closing prior PR ##{old_job.pr_number} (job ##{old_job.id}) per replace policy")
      begin
        GithubClient.for(repository: @task.repository, user: @task.user).close_pull_request(@task.repository.slug, old_job.pr_number)
      rescue StandardError => e
        Rails.logger.warn("[ScheduledTaskFire] failed to close PR ##{old_job.pr_number}: #{e.class}: #{e.message}")
      end
      old_job.close_with_reason!("replaced_by_scheduled_task")
    end
  end
end
