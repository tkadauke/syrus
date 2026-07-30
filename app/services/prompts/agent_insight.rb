module Prompts
  # Prompt for an agent_insight Job. Instructs the agent to inspect recent
  # workflow runs for the repository and surface improvement suggestions via
  # the `submit_insight` MCP tool.
  class AgentInsight
    def initialize(repository:, recent_jobs: [], user: nil)
      @repository  = repository
      @recent_jobs = recent_jobs
      @user        = user
    end

    def to_s
      [
        header,
        recent_jobs_section,
        instructions,
        memory_context
      ].compact_blank.join("\n\n")
    end

    private

    def header
      <<~TEXT
        You are an insight agent for the **#{@repository.slug}** repository.
        Your task is to inspect recent automated workflow runs and surface actionable
        improvement suggestions to the operator.

        You have read-only access to the repository source code via the workspace.
        Do NOT make any code changes or commits.
      TEXT
    end

    def recent_jobs_section
      return if @recent_jobs.empty?

      lines = @recent_jobs.map do |job|
        state = job.state
        kind  = job.kind
        title = job.issue_title.to_s.truncate(80)
        "- JOB-#{job.id} (#{kind}, #{state}): #{title}"
      end

      "## Recent Jobs (last 14 days)\n\n#{lines.join("\n")}"
    end

    def instructions
      <<~TEXT
        ## Your Task

        Inspect the repository's recent workflow runs and agent transcripts using the
        tools available to you (`read_live_state`, memory tools). Look for:

        - Repeated failures or struggle patterns across multiple Jobs
        - Inefficient agent behaviors (excessive tool calls, wrong approaches)
        - Missed opportunities for memory or knowledge capture
        - Configuration issues that cause unnecessary failures
        - Patterns that suggest a recurring task would be valuable

        For each concrete finding, call `submit_insight` with:
        - A concise `title` summarizing the issue
        - A `category` (e.g. "repeated_failure", "inefficiency", "configuration", "memory_gap", "recurring_task")
        - A `severity` ("low", "medium", or "high")
        - Your `confidence` (0.0–1.0) that this is a real pattern, not a one-off
        - `evidence` — an array of `{job_id, run_id, kind}` objects that support the finding
        - A `suggested_prompt` for a Job or ScheduledTask that would address it (optional)
        - A `memory_suggestion` with the exact text to store if this is a durable fact (optional)

        ## When to use each suggestion type

        **File a job suggestion (`suggested_prompt`)** when the finding is a code defect,
        missing behavior, misconfiguration, or architectural gap that requires a code change
        to resolve. Set `suggested_prompt` to a prompt that a future Job could act on.

        **File a memory suggestion (`memory_suggestion`)** when the finding is a behavioral
        pattern, constraint, or workaround that future coding agents running against this
        repository should be aware of — but where no code change is needed or possible right
        now. The text should be durable advice agents can act on.

        **File both** when there is a code fix that should be filed as a Job AND there is
        interim context agents need to carry while that fix has not yet landed (e.g.,
        "this bug exists until the fix lands; work around it by..."). Use `suggested_prompt`
        for the fix and `memory_suggestion` for the interim workaround.

        **Do NOT file a memory suggestion** for a finding that is purely a code bug with a
        clear fix. A memory that documents a bug which is about to be corrected misleads
        future agents after the fix lands. If the right action is to open a Job, set
        `suggested_prompt` and leave `memory_suggestion` blank.

        For durable facts you discover (e.g. recurring configuration issues, stable
        patterns), call `write_memory` to store them so future agents benefit.

        Call `submit_insight` once per distinct finding. Do not call it for speculative
        or single-instance observations below your confidence threshold. Aim for signal
        over volume.

        When you have finished your analysis and submitted all findings, stop.
      TEXT
    end

    def memory_context
      Prompts::MemoryContext.new(user: @user, repository_ids: [ @repository.id ]).to_s.presence
    end
  end
end
