module Prompts
  # Prompt for an agent_insight Job. Instructs the agent to inspect recent
  # workflow runs for the repository and surface improvement suggestions via
  # the `submit_insight` MCP tool.
  class AgentInsight
    def initialize(repository:, recent_jobs: [], analysis_window_start: nil, known_insights: [], user: nil)
      @repository            = repository
      @recent_jobs           = recent_jobs
      @analysis_window_start = analysis_window_start
      @known_insights        = known_insights
      @user                  = user
    end

    def to_s
      [
        header,
        analysis_window_section,
        recent_jobs_section,
        known_insights_section,
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

    def analysis_window_section
      return unless @analysis_window_start

      <<~TEXT
        ## Analysis Window

        Only analyze jobs and run transcripts that completed after #{@analysis_window_start.iso8601}.
        Do not re-examine transcripts from earlier runs.
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

    def known_insights_section
      return if @known_insights.empty?

      lines = @known_insights.map { |i| "- [#{i.id}] #{i.title} (#{i.state})" }

      <<~TEXT
        ## Known Insights

        The following insights have already been filed for this repository. Do not refile
        these unless you have evidence the underlying issue was reintroduced after a fix.
        Call `read_insight(id:)` to get the full details of any entry. Call `list_insights`
        to page through more insights beyond those listed here:

        #{lines.join("\n")}
      TEXT
    end

    def instructions
      <<~TEXT
        ## Your Task

        Inspect the repository's recent workflow runs and agent transcripts using the
        tools available to you (`read_live_state`, memory tools, `list_insights`,
        `read_insight`). Look for:

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

        For durable facts you discover (e.g. recurring configuration issues, stable
        patterns), call `write_memory` to store them so future agents benefit.
        Before suggesting a new memory, call `list_memories` to check whether a similar
        memory already exists for this repository. Only suggest a new memory if no
        sufficiently similar one is present.

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
