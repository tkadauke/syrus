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
        manual = !@require_due
        window_start = @task.fire_window_start(now: @now, manual: manual)
        return Result.new(job: nil, skipped: true, reason: "not_due") if window_start.blank?

        occurrence = @task.occurrences.find_or_create_by!(due_at: window_start)
        occurrence.lock!
        if occurrence.completed_at?
          return Result.new(job: occurrence.job, skipped: true, reason: "already_fired_window")
        end
        retrying_failed_attempt = occurrence.failed_attempt?(at: @now)

        return Result.new(job: nil, skipped: true, reason: "not_fireable") if @task.archived? || @task.fired?
        unless Syrus::Host::RepositoryPolicy.new(@task.user, @task.repository).write?
          @task.pause!(reason: "auto") unless @task.auto_paused? || @task.system_schedule?
          return Result.new(job: nil, skipped: true, reason: "repository_write_access_required")
        end
        if @require_due && !retrying_failed_attempt && !@task.due?(now: @now)
          return Result.new(job: nil, skipped: true, reason: "not_due")
        end

        if !retrying_failed_attempt && @task.fired_in_window?(window_start)
          return Result.new(job: nil, skipped: true, reason: "already_fired_window")
        end

        handler = ScheduledTasks::FireHandlers.for(@task)
        if handler.applicable_behaviors.include?(ScheduledTasks::FireHandlers::Base::PR_PILEUP_POLICY)
          policy = ScheduledTasks::PrPileupPolicies.for(@task.pr_pileup_policy).new(@task, fire_service: self)
          if (result = policy.check_pileup)
            occurrence.complete!(job: result.job, at: @now)
            return result
          end
        end

        job = handler.fire!(now: @now)
        if job.is_a?(Result)
          @task.record_fire!(at: @now)
          occurrence.complete!(job: job.job, at: @now)
          return job
        end
        unless job.is_a?(Syrus::Host::JobRecord) && job.scheduled_task_id == @task.id
          raise ArgumentError, "scheduled task fire handler must return a Job linked to its task"
        end

        @task.record_fire!(at: @now)
        @task.mark_fired_one_shot! if @task.one_shot?
        occurrence.complete!(job: job, at: @now)

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
          Syrus::Host::GithubClient.for(repository: @task.repository, user: @task.user).close_pull_request(@task.repository.slug, pr_number)
        rescue StandardError => e
          Rails.logger.warn("[ScheduledTasks::Fire] failed to close PR ##{pr_number}: #{e.class}: #{e.message}")
        end
        old_job.close_with_reason!("replaced_by_scheduled_task")
      end
    end
  end
end
