module Prompts
  # Prompt for the initial Run of a cron Job. Wraps the operator's
  # standing instruction (free-form, supports template variables) in
  # a Syrus-authored preamble that explains this is a scheduled
  # maintenance task and that the agent should NOT invent work.
  #
  # The interpolation step happens here at fire time — that way
  # {{date}} and {{last_fired_at}} reflect the moment the cron tick
  # actually went off, not whenever RunJob's worker happens to pick
  # up the queued Job. Future template variables get added to
  # SUPPORTED_VARIABLES.
  class ScheduledTask
    SUPPORTED_VARIABLES = %i[
      repo_slug
      repo_default_branch
      date
      last_fired_at
      last_successful_fire_at
      last_pr_number
      last_pr_state
    ].freeze

    # Maps a Job's closure_reason (or nil for open) to a label the agent
    # can reason about.
    PR_STATE_LABELS = {
      nil         => "open",
      "pr_merged" => "merged",
      "pr_closed" => "closed",
      "pr_approved" => "approved",
      "syrus_stop"  => "stopped",
      "too_many_failures" => "failed",
      "cancelled"         => "cancelled",
      "replaced_by_scheduled_task" => "replaced",
      "no_changes"        => "no_changes",
    }.freeze

    def initialize(scheduled_task:, fired_at: Time.current)
      @task = scheduled_task
      @fired_at = fired_at
    end

    def to_s
      [ preamble, interpolated_user_prompt, footer, SubmitSummaryInstructions::TEXT ].join("\n\n")
    end

    private

    def preamble
      <<~TXT.strip
        You're a scheduled maintenance task on `#{@task.repository.slug}`,
        fired by Syrus on a recurring schedule (the operator set this up
        once; it runs without human intervention each tick). The
        operator's standing instruction is below.

        Important: only commit changes if there's something genuinely
        worth changing. Survey the relevant area first; if the codebase
        is already in good shape with respect to this instruction,
        DO NOT manufacture changes to justify a run. Instead, run
        `submit_summary` with a one-line note explaining what you
        checked and that you found nothing to do, then exit without
        committing anything. Syrus will record the no-op run for the
        operator's audit trail.
      TXT
    end

    def footer
      <<~TXT.strip
        ---

        Standing instruction context:
        - Schedule kind: #{@task.kind}
        - Fired at: #{@fired_at.utc.iso8601}
        - Previous fire: #{@task.last_fired_at&.utc&.iso8601 || 'never'}
        - Last successful fire: #{@task.last_successful_fire_at&.utc&.iso8601 || 'never'}
        - Last PR: #{last_pr_summary}
      TXT
    end

    def interpolated_user_prompt
      @task.prompt.gsub(/\{\{\s*([a-z_]+)\s*\}\}/) do |match|
        var = Regexp.last_match(1).to_sym
        SUPPORTED_VARIABLES.include?(var) ? value_for(var) : match
      end
    end

    def value_for(var)
      case var
      when :repo_slug                 then @task.repository.slug
      when :repo_default_branch       then @task.repository.default_branch
      when :date                      then @fired_at.utc.to_date.iso8601
      when :last_fired_at             then @task.last_fired_at&.utc&.iso8601 || "never"
      when :last_successful_fire_at   then @task.last_successful_fire_at&.utc&.iso8601 || "never"
      when :last_pr_number            then last_pr_job ? last_pr_job.pr_number.to_s : "none"
      when :last_pr_state             then last_pr_job ? pr_state_label(last_pr_job) : "none"
      end
    end

    def last_pr_job
      @last_pr_job ||= @task.last_pr_job
    end

    def pr_state_label(job)
      PR_STATE_LABELS.fetch(job.closure_reason, "closed")
    end

    def last_pr_summary
      job = last_pr_job
      return "none" unless job
      "##{job.pr_number} (#{pr_state_label(job)})"
    end
  end
end
