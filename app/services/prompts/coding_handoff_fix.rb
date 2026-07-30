module Prompts
  # Prompt for a fresh workflow agent repairing pre-PR Coding Mode handoff
  # grader failures. Later loop iterations append Prompts::GradeFailureFeedback.
  class CodingHandoffFix
    def initialize(issue:, repo_slug:, branch_name:, handoff_snapshot:, recent_commits: [], epic: nil, job: nil)
      @issue = issue
      @repo_slug = repo_slug
      @branch_name = branch_name
      @handoff_snapshot = handoff_snapshot.to_h
      @recent_commits = recent_commits || []
      @epic = epic
      @job = job
    end

    def to_s
      sections = [
        context_section,
        issue_section,
        epic_context,
        handoff_section,
        commits_section,
        directives_section
      ].compact

      [ sections.join("\n\n---\n\n"), GitSafety::TEXT ].join("\n\n")
    end

    private

    def context_section
      <<~SECTION.strip
        This is a Coding Mode handoff repair for `#{@repo_slug}` on branch `#{@branch_name}`.

        A chat agent already committed the original implementation and Syrus is validating it before opening a PR.
        Required graders failed, so this fresh workflow agent owns the repair.

        Do not route work back to the original chat.
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

    def handoff_section
      return nil if @handoff_snapshot.blank?

      changed_files = Array(@handoff_snapshot["changed_files"]).presence
      lines = [
        "Source chat branch: #{@handoff_snapshot['source_branch'].presence || '(unknown)'}",
        "Captured handoff branch: #{@handoff_snapshot['handoff_branch'].presence || @branch_name}",
        "Captured handoff SHA: #{@handoff_snapshot['head_sha'].presence || '(unknown)'}",
        "Captured base SHA: #{@handoff_snapshot['base_sha'].presence || '(unknown)'}",
        "Captured at: #{@handoff_snapshot['captured_at'].presence || '(unknown)'}"
      ]
      lines << "Changed files at handoff:\n#{changed_files.map { |path| "- #{path}" }.join("\n")}" if changed_files

      [ "Committed handoff branch context:", lines.join("\n") ].join("\n\n")
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
        "Preserve the original handoff's intended behavior; do not broaden the feature or rewrite unrelated code.",
        "Do not ask the chat agent to take over. This workflow owns the repair until graders pass or the retry budget is exhausted.",
        "Commit to the current branch only when you actually change files."
      ].join("\n")
    end
  end
end
