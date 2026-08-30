module Prompts
  # Prompt for a fresh workflow agent repairing Local Mode handoff grader
  # failures. Later loop iterations append Prompts::GradeFailureFeedback.
  class LocalModeHandoffFix
    def initialize(issue:, repo_slug:, branch_name:, recent_commits: [], epic: nil, job: nil)
      @issue = issue
      @repo_slug = repo_slug
      @branch_name = branch_name
      @recent_commits = recent_commits || []
      @epic = epic
      @job = job
    end

    def to_s
      sections = [
        context_section,
        issue_section,
        epic_context,
        commits_section,
        directives_section
      ].compact

      [ sections.join("\n\n---\n\n"), GitSafety::TEXT, ShellCommandExecutionContract::TEXT ].join("\n\n")
    end

    private

    def context_section
      <<~SECTION.strip
        This is a Local Mode handoff repair for `#{@repo_slug}` on branch `#{@branch_name}`.

        The operator committed and pushed the original implementation from a local daemon checkout, and Syrus is validating it before opening or updating a PR.
        Required graders failed, so this fresh workflow agent owns the repair.

        Do not route work back to the originating Local Mode chat.
      SECTION
    end

    def issue_section
      <<~SECTION.strip
        Original Job context: #{@issue.title}

        #{@issue.body.to_s.strip.presence || "(empty)"}
      SECTION
    end

    def epic_context
      Prompts::EpicContext.new(epic: @epic, job: @job).to_s.presence
    end

    def commits_section
      return nil if @recent_commits.empty?

      lines = @recent_commits.map do |commit|
        sha = commit[:sha] || commit["sha"]
        subject = commit[:subject] || commit["subject"]
        "- #{sha.to_s[0, 7]} #{subject}"
      end

      <<~SECTION.strip
        Recent commits on the handoff branch (newest first):

        #{lines.join("\n")}
      SECTION
    end

    def directives_section
      [
        "Use the grader failure details below as the source of truth for what to repair.",
        "Fix the smallest concrete problem that makes the required graders pass.",
        "Preserve the operator's Local Mode implementation intent; do not broaden the feature or rewrite unrelated code.",
        "Do not ask the chat agent or operator's local daemon checkout to take over. This workflow owns the repair until graders pass or the retry budget is exhausted.",
        "Commit to the current branch only when you actually change files."
      ].join("\n")
    end
  end
end
