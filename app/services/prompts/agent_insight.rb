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

      lines = @known_insights.map do |i|
        "- [#{i.id}] #{i.title} (#{i.state}, #{i.effective_proposal_type})"
      end

      <<~TEXT
        ## Known Insights

        The following pending, accepted, and dismissed insights have already been filed
        for this repository. Review them for freshness before filing anything new. Do
        not refile these unless you have evidence the underlying issue was reintroduced
        after a fix.
        Do not refile known insights unless you have new evidence.
        Call `read_insight(id:)` to get the full details of any entry. Call `list_insights`
        to page through more insights beyond those listed here. If an existing insight is
        stale, duplicated, or superseded, file a structured `revise_existing_insight`
        suggestion that references `target_insight_id` and explains the replacement or
        retirement path:

        #{lines.join("\n")}
      TEXT
    end

    def instructions
      <<~TEXT
        ## Your Task

        Inspect the repository's recent workflow runs and agent transcripts using the
        tools available to you (`read_live_state`, `read_run_worker_health`, memory
        tools, `list_insights`, `read_insight`). Look for:

        - Repeated failures or struggle patterns across multiple Jobs
        - Inefficient agent behaviors (excessive tool calls, wrong approaches)
        - Missed opportunities for memory or knowledge capture
        - Existing pending or accepted insights that are stale, duplicated, or superseded
          by current repository state
        - Existing repository memories that are stale, wrong, or describe bugs already fixed
        - Configuration issues that cause unnecessary failures
        - Worker host pressure that repeatedly coincides with a step kind or grader
          (for example, rspec Runs lining up with CPU starvation)
        - Patterns that suggest a recurring task would be valuable

        For each concrete finding, call `submit_insight` with:
        - A concise `title` summarizing the issue
        - A `category` (e.g. "repeated_failure", "inefficiency", "configuration", "memory_gap", "recurring_task")
        - A `severity` ("low", "medium", or "high")
        - Your `confidence` (0.0–1.0) that this is a real pattern, not a one-off
        - `evidence` — an array of `{job_id, run_id, kind}` objects that support the finding.
          Use `read_run_worker_health` when host pressure, CPU starvation, memory,
          disk, or IO pressure may explain a Run or repeated step behavior.
        - A `suggested_prompt` for a Job or ScheduledTask that would address it (optional)
        - A `memory_suggestion` with the exact text to store if this is a durable fact (optional)
        - A `proposal_type` (`create_job`, `save_memory`, `remove_memory`,
          `revise_existing_insight`, or `informational`). Existing legacy behavior is still
          supported, but use the explicit field for new suggestions.
        - For `remove_memory`: include `target_memory_id`, the stale or wrong
          `stale_memory_text`, and `stale_memory_evidence` explaining why the memory no
          longer matches current code, docs, recent jobs, or accepted implementation state.
        - For `revise_existing_insight`: include `target_insight_id` and explain what is
          stale, duplicated, or superseded.

        ## When to use each suggestion type

        **File a job suggestion (`proposal_type: "create_job"` with `suggested_prompt`)**
        when the finding is a code defect, missing behavior, misconfiguration, or
        architectural gap that requires a code change to resolve. Set `suggested_prompt`
        to a prompt that a future Job could act on.

        **File a memory suggestion (`proposal_type: "save_memory"` with
        `memory_suggestion`)** when the finding is a behavioral pattern, constraint, or
        workaround that future coding agents running against this repository should be
        aware of — but where no code change is needed or possible right now. The text
        should be durable advice agents can act on.

        **File a stale-memory removal (`proposal_type: "remove_memory"`)** when an
        existing memory is stale, wrong, or describes a bug that has since been fixed.
        You must call `list_memories` and `read_memory` first, verify against current
        repository reality, then submit the removal proposal with `target_memory_id`,
        `stale_memory_text`, and `stale_memory_evidence`. Do NOT call `delete_memory`
        during an insight run; operators accept removals through audited application code.

        **File an existing-insight revision (`proposal_type: "revise_existing_insight"`)**
        when a pending, accepted, or dismissed insight is stale, duplicated, or superseded.
        Include `target_insight_id` and concrete evidence for the revision or retirement.

        **File both** when there is a code fix that should be filed as a Job AND there is
        interim context agents need to carry while that fix has not yet landed (e.g.,
        "this bug exists until the fix lands; work around it by..."). Use `suggested_prompt`
        for the fix and `memory_suggestion` for the interim workaround.

        **Do NOT file a memory suggestion** for a finding that is purely a code bug with a
        clear fix. A memory that documents a bug which is about to be corrected misleads
        future agents after the fix lands. If the right action is to open a Job, set
        `suggested_prompt` and leave `memory_suggestion` blank.

        For durable facts you discover (e.g. recurring configuration issues, stable
        patterns), call `write_memory` to store them so future agents benefit only after
        checking existing memories. Before suggesting or writing a new memory, call
        `list_memories` and `read_memory` for repository-relevant memories to check
        whether a similar memory already exists for this repository and whether existing
        memories still match current code and recent accepted work. Only suggest a new memory if no sufficiently
        similar one is present. If a memory needs replacement, propose removal of the stale
        memory and a separate non-conflicting memory suggestion for the replacement.

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
