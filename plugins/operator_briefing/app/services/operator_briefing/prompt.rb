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

        Call `submit_briefing_block` once for each section as you produce it. For this phase,
        submit only:

        - `narrative` blocks with `payload.text`
        - `link_card` blocks with `payload.entity_type`, `payload.entity_id`, `payload.title`,
          `payload.path`, and optional `payload.description`

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
