module Prompts
  # Prompt for follow-up Runs triggered from Syrus Chat operator feedback.
  # GitHub-sourced content trust boundary
  class ChatFeedback
    include GithubContentTrust

    MAX_ISSUE_BODY_BYTES = 20_000
    MAX_FEEDBACK_BYTES = 10_000
    MAX_COMMENT_BYTES = 4_000
    MAX_COMMENTS = 20
    MAX_COMMENTS_BYTES = 30_000
    MAX_SUMMARIES_BYTES = 20_000

    def initialize(issue:, feedback:, diff_comments: [], prior_summaries: [], recent_commits: [], epic: nil, job: nil, user: nil, repository_ids: [], injected_context: [], spill: nil)
      @issue = issue
      @feedback = feedback
      @diff_comments = Array(diff_comments)
      @prior_summaries = prior_summaries || []
      @recent_commits = recent_commits || []
      @epic = epic
      @job = job
      @user = user
      @repository_ids = repository_ids
      @injected_context = Array(injected_context).compact
      @spill = spill
    end

    def to_s
      sections = [
        github_content_trust_boundary,
        issue_section,
        epic_context,
        prior_context_section,
        feedback_section,
        diff_comments_section,
        commits_section,
        memory_context,
        directives_section,
        injected_context_section
      ].compact

      [ sections.join("\n\n---\n\n"), GitSafety::TEXT, ShellCommandExecutionContract::TEXT, SubmitSummaryInstructions::TEXT ].join("\n\n")
    end

    private

    def issue_section
      <<~SECTION.strip
        Original issue: #{@issue.title}

        #{Truncate.text(@issue.body, max_bytes: MAX_ISSUE_BODY_BYTES, label: "issue body", spill: @spill)}
      SECTION
    end

    def epic_context
      Prompts::EpicContext.new(epic: @epic, job: @job).to_s.presence
    end

    def memory_context
      Prompts::MemoryContext.new(user: @user, repository_ids: @repository_ids).to_s.presence
    end

    def prior_context_section
      return nil if @prior_summaries.empty?

      lines = @prior_summaries.each_with_index.map do |summary, index|
        "Round #{index + 1}:\n#{summary}"
      end
      summaries = Truncate.text(lines.join("\n\n"), max_bytes: MAX_SUMMARIES_BYTES, label: "prior summaries", spill: @spill)

      <<~SECTION.strip
        What you've done on this PR in previous feedback rounds:

        #{summaries}
      SECTION
    end

    def feedback_section
      <<~SECTION.strip
        Operator feedback from Syrus Chat:

        #{Truncate.text(@feedback, max_bytes: MAX_FEEDBACK_BYTES, label: "feedback", spill: @spill)}
      SECTION
    end

    def diff_comments_section
      return nil if @diff_comments.empty?

      <<~SECTION.strip
        Anchored diff comments:

        #{render_diff_comments}
      SECTION
    end

    def commits_section
      return nil if @recent_commits.empty?

      lines = @recent_commits.map do |commit|
        sha = commit[:sha] || commit["sha"]
        subject = commit[:subject] || commit["subject"]
        "- #{sha.to_s[0, 7]} #{subject}"
      end

      <<~SECTION.strip
        Recent commits on the working branch (newest first):

        #{lines.join("\n")}
      SECTION
    end

    def directives_section
      [
        "Address the operator feedback from Syrus Chat.",
        "Treat anchored diff comments as precise code-review feedback tied to the listed file and line.",
        "Do NOT broaden the work beyond the requested feedback.",
        "Do NOT revert earlier work unless the feedback explicitly asks for it.",
        "Make commits to the current branch."
      ].join("\n")
    end

    def injected_context_section
      return nil if @injected_context.empty?

      @injected_context.join("\n\n")
    end

    def render_diff_comments
      Truncate.collection(@diff_comments, max_items: MAX_COMMENTS, max_bytes: MAX_COMMENTS_BYTES, spill: @spill) do |comment|
        render_diff_comment(comment.to_h)
      end
    end

    def render_diff_comment(comment)
      side = value(comment, "side")
      line = value(comment, "line").presence || (side == "left" ? value(comment, "old_line") : value(comment, "new_line"))
      refs = [ value(comment, "base_ref").presence, value(comment, "head_ref").presence ].compact.join("...")
      refs = "Refs: #{refs}\n" if refs.present?

      <<~COMMENT.strip
        [#{value(comment, "path")}:#{line} #{side}]
        #{refs}Context:
        #{indent(value(comment, "diff_hunk").to_s.presence || "(no hunk snapshot)")}

        Comment:
        #{Truncate.text(value(comment, "body"), max_bytes: MAX_COMMENT_BYTES, label: "comment", spill: @spill)}
      COMMENT
    end

    def value(hash, key)
      hash[key] || hash[key.to_sym]
    end

    def indent(text, by: 2)
      pad = " " * by
      text.lines.map { |line| pad + line }.join.chomp + "\n"
    end
  end
end
