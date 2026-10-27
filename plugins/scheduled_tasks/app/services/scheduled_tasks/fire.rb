module ScheduledTasks
  # Fires one schedule: renders its prompt and creates the Job.
  class Fire
    Result = Data.define(:job, :skipped, :reason) do
      def fired? = !skipped
    end

    attr_reader :now

    def initialize(task, now: Time.current, require_due: false)
      @task = task
      @now = now
      @require_due = require_due
    end

    # Spawn the target handler's Job for this fire.
    # Stamps last_fired_at unconditionally so the next due-check uses
    # this tick as its baseline. Guards the current fire window under a
    # row lock so concurrent pollers/manual fires cannot duplicate Jobs.
    # Marks one_shot tasks as `fired` after they spawn their Job. The default
    # target honors pr_pileup_policy:
    #
    #   skip     — don't fire if a prior PR is still open
    #   pile     — fire regardless (lets PRs stack)
    #   replace  — close prior open PRs from this task before firing
    def call
      @task.with_lock do
        @task.reload
        return Result.new(job: nil, skipped: true, reason: "not_fireable") if @task.archived? || @task.fired?
        unless RepositoryPolicy.new(@task.user, @task.repository).write?
          @task.pause!(reason: "auto") unless @task.auto_paused?
          return Result.new(job: nil, skipped: true, reason: "repository_write_access_required")
        end
        return Result.new(job: nil, skipped: true, reason: "not_due") if @require_due && !@task.due?(now: @now)

        manual = !@require_due
        window_start = @task.fire_window_start(now: @now, manual: manual)
        return Result.new(job: nil, skipped: true, reason: "not_due") if window_start.blank?
        if @task.fired_in_window?(window_start)
          return Result.new(job: nil, skipped: true, reason: "already_fired_window")
        end

        handler = ScheduledTasks::FireHandlers.for(@task)
        if handler.applicable_behaviors.include?(ScheduledTasks::FireHandlers::Base::PR_PILEUP_POLICY)
          policy = ScheduledTasks::PrPileupPolicies.for(@task.pr_pileup_policy).new(@task, fire_service: self)
          if (result = policy.check_pileup)
            return result
          end
        end

        job = handler.fire!(now: @now)
        unless job.is_a?(Job) && job.scheduled_task_id == @task.id
          raise ArgumentError, "scheduled task fire handler must return a Job linked to its task"
        end

        @task.record_fire!(at: @now)
        @task.mark_fired_one_shot! if @task.one_shot?

        Result.new(job: job, skipped: false, reason: nil)
      end
    end

    private

    public

    def close_prior_open_prs
      @task.open_pr_jobs.find_each do |old_job|
        pr_number = old_job.external_pr_number || old_job.pr_number
        Rails.logger.info("[ScheduledTasks::Fire] task ##{@task.id} closing prior PR ##{pr_number} (#{old_job.slug}) per replace policy")
        begin
          GithubClient.for(repository: @task.repository, user: @task.user).close_pull_request(@task.repository.slug, pr_number)
        rescue StandardError => e
          Rails.logger.warn("[ScheduledTasks::Fire] failed to close PR ##{pr_number}: #{e.class}: #{e.message}")
        end
        old_job.close_with_reason!("replaced_by_scheduled_task")
      end
    end
  end
end
