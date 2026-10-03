module OperatorBriefing
  class Prompt
    SIGNALS = [
      "new dependencies or lockfile changes",
      "schema or migration changes",
      "public API or interface changes",
      "deleted or weakened test coverage",
      "deviations from CLAUDE.md or repository conventions",
      "adversarial or visual review findings that were overridden or dismissed",
      "security-sensitive paths such as auth, secrets, permissions, or credential handling"
    ].freeze

    def initialize(briefing:, revision:, user:)
      @briefing = briefing
      @revision = revision
      @user = user
    end

    def to_s
      [
        header,
        window,
        required_sources,
        source_preferences,
        notable_signals,
        block_instructions,
        memory_context
      ].compact_blank.join("\n\n")
    end

    private

    attr_reader :briefing, :revision, :user

    def header
      <<~TEXT
        You are generating the Operator Briefing for **#{briefing.repository.slug}**.
        This is a read-only synthesis run. Do not edit files, create commits, push,
        open PRs, or mutate Jobs other than calling the briefing MCP tools.
      TEXT
    end

    def window
      <<~TEXT
        ## Briefing Window

        Analyze activity from #{briefing.window_start.iso8601} through #{briefing.window_end.iso8601}.
        Current briefing_id=#{briefing.id}; revision_id=#{revision.id}; job_id=#{briefing.job_id}.
      TEXT
    end

    def required_sources
      <<~TEXT
        ## Required Sources

        Use `read_briefing_git_diff` for repository changes across the briefing window.
        Use `list_briefing_recent_workflows` to inspect completed Workflows in this repository during the same window.
        Use run transcripts, artifacts, summaries, and review artifacts from those Workflows when available.
        Use `list_design_docs` and `read_design_doc` to look for open Design Doc threads on docs the operator owns,
        especially threads with no operator reply since the last comment.
      TEXT
    end

    def source_preferences
      preferences = SourcePreference.effective_for_user(user).values.sort_by(&:source_key)
      enabled = preferences.select(&:enabled?).map(&:source_key)
      disabled = preferences.reject(&:enabled?).map(&:source_key)

      <<~TEXT
        ## Source Preferences

        Enabled sources: #{enabled.any? ? enabled.join(", ") : "none"}.
        Disabled sources: #{disabled.any? ? disabled.join(", ") : "none"}.

        Prioritize enabled sources and omit disabled sources unless they are necessary
        evidence for an enabled source.
      TEXT
    end

    def notable_signals
      lines = SIGNALS.map { |signal| "- #{signal}" }.join("\n")
      <<~TEXT
        ## Notable-Change Signals

        Apply your own judgment directly to the diff and workflow/design-doc history.
        Do not assume a deterministic detector has pre-labeled the important items.
        Look specifically for:

        #{lines}
      TEXT
    end

    def block_instructions
      <<~TEXT
        ## Output

        Call `submit_briefing_block` once for each section as you produce it. Supported
        block kinds:

        - `narrative` blocks with `payload.text` and optional `payload.dive_candidates`.
          Dive candidates must reference spans that appear verbatim in `payload.text`;
          include at most #{BriefingRevision::MAX_DIVE_CANDIDATES} across the whole briefing.
        - `chart` blocks with `payload.chart_type`, `payload.title`, and
          `payload.data` entries containing `label` and `value`.
        - `image` blocks with `payload.workflow_id`, `payload.type`, `payload.title`,
          and optional `payload.caption`, only referencing existing screenshot typed
          artifacts from summarized Workflows.
        - `artifact` blocks with `payload.workflow_id`, `payload.type`, `payload.title`,
          and optional `payload.caption`, only referencing existing non-image typed
          artifacts from summarized Workflows.
        - `link_card` blocks with `payload.entity_type`, `payload.entity_id`, `payload.title`,
          `payload.path`, and optional `payload.description`

        For Design Docs link cards, visible text may refer to the canonical
        `DOC-<id>` ref, but `payload.path` must use the numeric app path
        `/design_docs/<id>`.

        Never generate fresh image or artifact content for this briefing. Only use
        `image` or `artifact` when the originating Workflow already captured that
        typed artifact.

        Keep the writing concise and evidence-driven. Prefer a small number of high-signal
        blocks over a broad activity log. Include links to existing Jobs, Workflows, PRs,
        Design Docs, or repository pages whenever they are the clearest evidence.
      TEXT
    end

    def memory_context
      Prompts::MemoryContext.new(user: user, repository_ids: [ briefing.repository_id ]).to_s.presence
    end
  end
end
